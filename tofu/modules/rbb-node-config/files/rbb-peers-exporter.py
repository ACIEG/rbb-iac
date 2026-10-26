#!/usr/bin/env python3
"""Exportador Prometheus de um nó RBB (porta 9546, só VPC): quem está conectado a quem, portas dos
peers esperados, disco e memória real do contêiner do Besu. Só biblioteca padrão. Executa como root
(lê o cgroup do contêiner via docker inspect).

Métricas:
  rbb_peer_connected{organization,peer,peer_type,direction,own,in_consensus}  1 por sessão P2P ativa
  rbb_peer_expected{organization,peer,peer_type,own,in_consensus}             1 por peer em static-nodes / bootnodes
  rbb_peer_port_open{organization,peer,peer_type,own,in_consensus}            1 se a porta P2P do peer esperado aceita TCP
  rbb_consensus_validators                                                    validators no consenso QBFT agora
  rbb_blocks_proposed_last100{organization,validator,own,address}            blocos propostos por validator nos últimos 100
  rbb_last_proposed_block{organization,validator,own,address}                 último bloco proposto por validator
  rbb_missed_rounds_last100{organization,validator,own,address}              vezes que o validator não propôs na sua vez (rodada expirou), últimos 100 blocos
  rbb_rounds_expired_last100                                                  blocos fechados em round > 0 nos últimos 100
  rbb_disk_bytes{mount,kind="total|used"}                        disco raiz e volume de dados
  rbb_besu_memory_anon_bytes / rbb_besu_memory_limit_bytes       memória real (anon) e limite do contêiner
  rbb_node_info{role}                                            papel do nó (boot, validator, writer, observer-boot, observer)
  rbb_exporter_scrape_seconds                                    duração da coleta
"""
import http.server, json, os, re, socket, subprocess, sys, threading, time, urllib.request

ENV = {}
for line in open("/etc/rbb/node.env"):
    line = line.strip()
    if "=" in line and not line.startswith("#"):
        k, v = line.split("=", 1); ENV[k] = v.strip().strip('"')
NODE, NTYPE = ENV["NODE_NAME"], ENV["NODE_TYPE"]
RPC = f"http://127.0.0.1:{ENV.get('RPC_PORT', '8545')}"
DATA = ENV.get("DATA_MOUNT", "/srv/rbb")
SN = f"{DATA}/start-network"
MAP_FILE = "/etc/rbb/peers-map.json"
PORT = int(os.environ.get("EXPORTER_PORT", "9546"))
CACHE_S = 20

def rpc(method, params=None):
    req = urllib.request.Request(RPC, data=json.dumps({"jsonrpc": "2.0", "method": method, "params": params or [], "id": 1}).encode(),
                                 headers={"Content-Type": "application/json"})
    return json.load(urllib.request.urlopen(req, timeout=8)).get("result")

# Várias organizações publicam boot, validator e writer no MESMO IP (portas diferentes): o mapa é
# ip -> lista de entradas; a escolha usa a porta quando conhecida (sessões de saída e peers esperados)
# e, nas sessões de entrada (porta efêmera), o tipo que o nosso papel espera do outro lado.
PREFER = {"validator": "validator", "boot": "boot", "writer": "boot", "observer-boot": "boot", "observer": "observer-boot"}
def load_map():
    m = {}
    try:
        for e in json.load(open(MAP_FILE)):
            m.setdefault(e["ip"], []).append(e)
    except Exception:
        pass
    return m

def expected_enodes():
    out = []
    try:
        out += json.load(open(f"{SN}/volumes/{NODE}/static-nodes.json"))
    except Exception:
        pass
    if NTYPE == "boot":
        try:
            out += json.load(open(f"{SN}/.env.configs/genesis.json")).get("config", {}).get("discovery", {}).get("bootnodes", [])
        except Exception:
            pass
    res = []
    for e in out:
        m = re.match(r"enode://[0-9a-fA-F]+@([^:]+):(\d+)", e)
        if m: res.append((m.group(1), int(m.group(2))))
    return res

def port_open(host, port, timeout=3):
    try:
        with socket.create_connection((host, port), timeout=timeout):
            return 1
    except Exception:
        return 0

def entry(m, ip, port=None):
    cands = m.get(ip) or []
    e = None
    if port is not None:
        e = next((c for c in cands if int(c.get("port") or 0) == int(port)), None)
    if e is None and cands:
        e = next((c for c in cands if c.get("type") == PREFER.get(NTYPE)), cands[0])
    return e

def labels_for(m, ip, port, cons, fallback_type=""):
    e = entry(m, ip, port)
    if not e:
        return {"organization": "desconhecida", "peer": ip, "peer_type": fallback_type, "own": "false", "in_consensus": "false"}
    vid = (e.get("id") or "").lower().replace("0x", "")
    return {"organization": e.get("organization", "?"), "peer": e.get("node", ip), "peer_type": e.get("type", fallback_type),
            "own": "true" if e.get("own") else "false", "in_consensus": "true" if (vid and vid in cons) else "false"}

def esc(s): return str(s).replace("\\", "\\\\").replace('"', '\\"')
def fmt(name, labels, value):
    l = ",".join(f'{k}="{esc(v)}"' for k, v in labels.items())
    return f"{name}{{{l}}} {value}"

def cgroup_mem():
    try:
        cid = subprocess.check_output(["docker", "inspect", "-f", "{{.Id}}", f"start-network-{NODE}-1"], timeout=8).decode().strip()
        base = None
        for root in ("/sys/fs/cgroup/system.slice", "/sys/fs/cgroup"):
            for d in os.listdir(root) if os.path.isdir(root) else []:
                if cid in d: base = os.path.join(root, d); break
            if base: break
        if not base: return None, None
        anon = None
        for line in open(f"{base}/memory.stat"):
            if line.startswith("anon "): anon = int(line.split()[1]); break
        mx = open(f"{base}/memory.max").read().strip()
        return anon, (None if mx == "max" else int(mx))
    except Exception:
        return None, None

def consensus_set():
    """Endereços (sem 0x, minúsculos) dos validators no consenso QBFT agora."""
    try:
        return {a.lower().replace("0x", "") for a in (rpc("qbft_getValidatorsByBlockNumber", ["latest"]) or [])}
    except Exception:
        return set()

# Rodadas perdidas: blocos fechados em round > 0 indicam que o proponente do round 0 (e dos seguintes) não
# propôs a tempo. No QBFT do Besu o proponente de (altura, round) é validators[(i(proponente do bloco pai) + 1 + round) % n],
# com validators ordenados por endereço. Mantém uma janela dos últimos 100 blocos, lida incrementalmente.
import collections
_missed = collections.deque()      # (bloco, [endereços que perderam a vez])
_missed_state = {"last": 0, "prev_miner": None}

def rlp_decode(b, i=0):
    x = b[i]
    if x < 0x80: return b[i:i+1], i+1
    if x < 0xb8: l = x-0x80; return b[i+1:i+1+l], i+1+l
    if x < 0xc0: ll = x-0xb7; l = int.from_bytes(b[i+1:i+1+ll], "big"); s0 = i+1+ll; return b[s0:s0+l], s0+l
    if x < 0xf8: l = x-0xc0; s0 = i+1
    else: ll = x-0xf7; l = int.from_bytes(b[i+1:i+1+ll], "big"); s0 = i+1+ll
    end = s0+l; out = []
    while s0 < end:
        v, s0 = rlp_decode(b, s0); out.append(v)
    return out, end

def block_round(extra_hex):
    try:
        items, _ = rlp_decode(bytes.fromhex(extra_hex[2:]))
        r = items[3]
        return int.from_bytes(r, "big") if isinstance(r, (bytes, bytearray)) else 0
    except Exception:
        return 0

def update_missed():
    head = int(rpc("eth_blockNumber"), 16)
    start = _missed_state["last"] + 1 if _missed_state["last"] else max(head - 100, 1)
    if start > head: return
    if head - start > 300: start = head - 300           # retomada após parada longa
    prev = _missed_state["prev_miner"]
    if prev is None:
        prev = rpc("eth_getBlockByNumber", [hex(start - 1), False])["miner"].lower()
    for n in range(start, head + 1):
        blk = rpc("eth_getBlockByNumber", [hex(n), False])
        miner = blk["miner"].lower(); rnd = block_round(blk["extraData"]); missed = []
        if rnd > 0:
            vals = sorted(a.lower() for a in (rpc("qbft_getValidatorsByBlockNumber", [hex(n - 1)]) or []))
            if prev in vals and vals:
                i = vals.index(prev)
                missed = [vals[(i + 1 + r) % len(vals)] for r in range(rnd)]
        _missed.append((n, missed)); prev = miner
    _missed_state.update(last=head, prev_miner=prev)
    while len(_missed) > 100: _missed.popleft()

def collect():
    t0 = time.time(); lines = [fmt("rbb_node_info", {"role": NTYPE}, 1)]
    m = load_map(); cons = consensus_set()
    lines.append(f"rbb_consensus_validators {len(cons)}")
    # sessões ativas
    try:
        for p in rpc("admin_peers") or []:
            addr = re.sub(r"^[^/]*/", "", p["network"]["remoteAddress"]); ip, rport = addr.rsplit(":", 1)
            inbound = bool(p["network"].get("inbound"))
            lab = labels_for(m, ip, None if inbound else int(rport), cons)
            lab["direction"] = "inbound" if inbound else "outbound"
            lines.append(fmt("rbb_peer_connected", lab, 1))
    except Exception as ex:
        lines.append(f"# admin_peers falhou: {esc(ex)}")
    # esperados + porta
    seen = set()
    for host, port in expected_enodes():
        ip = host
        try: ip = socket.gethostbyname(host)
        except Exception: pass
        if (ip, port) in seen: continue
        seen.add((ip, port))
        lab = labels_for(m, ip, port, cons)
        lines.append(fmt("rbb_peer_expected", lab, 1))
        lines.append(fmt("rbb_peer_port_open", lab, port_open(ip, port)))
    # nomes por endereço do validator (id no nodes.json)
    byaddr = {}
    for lst in m.values():
        for e in lst:
            if e.get("id"):
                byaddr[e["id"].lower()] = e
    # blocos propostos por validator nos últimos 100 blocos (qbft_getSignerMetrics)
    try:
        for sm in rpc("qbft_getSignerMetrics") or []:
            addr = sm.get("address", "").lower()
            e = byaddr.get(addr, {})
            lab = {"organization": e.get("organization", "desconhecida"), "validator": e.get("node", addr[:10]), "own": "true" if e.get("own") else "false", "address": addr}
            lines.append(fmt("rbb_blocks_proposed_last100", lab, int(sm.get("proposedBlockCount", "0x0"), 16)))
            lines.append(fmt("rbb_last_proposed_block", lab, int(sm.get("lastProposedBlockNumber", "0x0"), 16)))
    except Exception as ex:
        lines.append(f"# qbft_getSignerMetrics falhou: {esc(ex)}")
    # rodadas perdidas por validator nos últimos 100 blocos
    try:
        update_missed()
        counts = {}
        for _, lst in _missed:
            for a in lst: counts[a] = counts.get(a, 0) + 1
        lines.append(fmt("rbb_rounds_expired_last100", {}, sum(1 for _, l in _missed if l)))
        for addr, c in counts.items():
            e = byaddr.get(addr, {})
            lab = {"organization": e.get("organization", "desconhecida"), "validator": e.get("node", addr[:10]), "own": "true" if e.get("own") else "false", "address": addr}
            lines.append(fmt("rbb_missed_rounds_last100", lab, c))
    except Exception as ex:
        lines.append(f"# rodadas perdidas falhou: {esc(ex)}")
    # disco
    for mount in sorted({"/", DATA}):
        try:
            st = os.statvfs(mount); total = st.f_blocks * st.f_frsize; free = st.f_bavail * st.f_frsize
            lines.append(fmt("rbb_disk_bytes", {"mount": mount, "kind": "total"}, total))
            lines.append(fmt("rbb_disk_bytes", {"mount": mount, "kind": "used"}, total - free))
        except Exception:
            pass
    # memória real do contêiner
    anon, limit = cgroup_mem()
    if anon is not None: lines.append(f"rbb_besu_memory_anon_bytes {anon}")
    if limit is not None: lines.append(f"rbb_besu_memory_limit_bytes {limit}")
    lines.append(f"rbb_exporter_scrape_seconds {time.time() - t0:.3f}")
    return "\n".join(lines) + "\n"

_lock = threading.Lock(); _cache = {"t": 0, "body": ""}
class H(http.server.BaseHTTPRequestHandler):
    def log_message(self, *a): pass
    def do_GET(self):
        if self.path != "/metrics":
            self.send_response(404); self.end_headers(); return
        with _lock:
            if time.time() - _cache["t"] > CACHE_S:
                _cache["body"] = collect(); _cache["t"] = time.time()
            body = _cache["body"].encode()
        self.send_response(200); self.send_header("Content-Type", "text/plain; version=0.0.4"); self.end_headers(); self.wfile.write(body)

if __name__ == "__main__":
    if len(sys.argv) > 1 and sys.argv[1] == "--once":
        sys.stdout.write(collect()); sys.exit(0)
    http.server.ThreadingHTTPServer(("0.0.0.0", PORT), H).serve_forever()
