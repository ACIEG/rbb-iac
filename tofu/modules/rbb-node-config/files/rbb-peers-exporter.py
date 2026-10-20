#!/usr/bin/env python3
"""Exportador Prometheus de um nó RBB (porta 9546, só VPC): quem está conectado a quem, portas dos
peers esperados, disco e memória real do contêiner do Besu. Só biblioteca padrão. Executa como root
(lê o cgroup do contêiner via docker inspect).

Métricas:
  rbb_peer_connected{organization,peer,peer_type,direction,own}  1 por sessão P2P ativa
  rbb_peer_expected{organization,peer,peer_type,own}             1 por peer em static-nodes / bootnodes
  rbb_peer_port_open{organization,peer,peer_type,own}            1 se a porta P2P do peer esperado aceita TCP
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

def load_map():
    try:
        return {e["ip"]: e for e in json.load(open(MAP_FILE))}
    except Exception:
        return {}

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

def label(m, ip, fallback_type=""):
    e = m.get(ip)
    if e: return e.get("organization", "?"), e.get("node", ip), e.get("type", fallback_type), "true" if e.get("own") else "false"
    return "desconhecida", ip, fallback_type, "false"

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

def collect():
    t0 = time.time(); lines = [fmt("rbb_node_info", {"role": NTYPE}, 1)]
    m = load_map()
    # sessões ativas
    try:
        for p in rpc("admin_peers") or []:
            addr = p["network"]["remoteAddress"]; ip = re.sub(r"^[^/]*/", "", addr).rsplit(":", 1)[0]
            org, name, typ, own = label(m, ip)
            lines.append(fmt("rbb_peer_connected", {"organization": org, "peer": name, "peer_type": typ, "direction": "inbound" if p["network"].get("inbound") else "outbound", "own": own}, 1))
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
        org, name, typ, own = label(m, ip)
        lab = {"organization": org, "peer": name, "peer_type": typ, "own": own}
        lines.append(fmt("rbb_peer_expected", lab, 1))
        lines.append(fmt("rbb_peer_port_open", lab, port_open(ip, port)))
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
