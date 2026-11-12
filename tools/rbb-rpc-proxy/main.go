// rbb-rpc-proxy: proxy JSON-RPC com lista de métodos permitidos na frente de um nó Besu.
//
// Fica entre a aplicação e o RPC do writer: aceita só os métodos listados (por padrão, leitura
// eth_/net_/web3_clientVersion e eth_sendRawTransaction) e responde -32601 aos demais, inclusive
// dentro de lotes (batch). Não altera o Besu nem exige autenticação; a restrição de quem alcança
// o proxy fica no firewall. Só biblioteca padrão.
//
// Ambiente: LISTEN (padrão :8546), UPSTREAM (padrão http://127.0.0.1:8545),
// ALLOW (lista separada por vírgula; vazio = padrão), MAX_BODY (bytes, padrão 1048576).
package main

import (
	"bytes"
	"encoding/json"
	"io"
	"log"
	"net/http"
	"os"
	"strconv"
	"strings"
	"time"
)

var defaultAllow = []string{
	"eth_blockNumber", "eth_chainId", "eth_call", "eth_estimateGas", "eth_gasPrice", "eth_feeHistory",
	"eth_maxPriorityFeePerGas", "eth_getBalance", "eth_getCode", "eth_getStorageAt", "eth_getLogs",
	"eth_getBlockByHash", "eth_getBlockByNumber", "eth_getBlockTransactionCountByNumber",
	"eth_getTransactionByHash", "eth_getTransactionByBlockNumberAndIndex", "eth_getTransactionReceipt",
	"eth_getTransactionCount", "eth_sendRawTransaction", "eth_syncing", "eth_protocolVersion",
	"net_version", "net_listening", "net_peerCount", "web3_clientVersion",
}

type rpcReq struct {
	JSONRPC string          `json:"jsonrpc"`
	ID      json.RawMessage `json:"id"`
	Method  string          `json:"method"`
	Params  json.RawMessage `json:"params,omitempty"`
}

type rpcErr struct {
	JSONRPC string          `json:"jsonrpc"`
	ID      json.RawMessage `json:"id"`
	Error   rpcErrBody      `json:"error"`
}
type rpcErrBody struct {
	Code    int    `json:"code"`
	Message string `json:"message"`
}

type proxy struct {
	upstream string
	allow    map[string]bool
	client   *http.Client
	maxBody  int64
}

func newProxy(upstream string, allow []string, maxBody int64) *proxy {
	m := map[string]bool{}
	for _, a := range allow {
		if a = strings.TrimSpace(a); a != "" {
			m[a] = true
		}
	}
	return &proxy{upstream: upstream, allow: m, client: &http.Client{Timeout: 60 * time.Second}, maxBody: maxBody}
}

func deny(id json.RawMessage, code int, msg string) rpcErr {
	if len(id) == 0 {
		id = json.RawMessage("null")
	}
	return rpcErr{JSONRPC: "2.0", ID: id, Error: rpcErrBody{Code: code, Message: msg}}
}

// filter separa as chamadas permitidas das recusadas. Devolve o corpo a encaminhar (ou nil se nada
// passou), as respostas de recusa e se a requisição era um lote.
func (p *proxy) filter(body []byte) (forward []byte, denied []rpcErr, batch bool, err error) {
	trim := bytes.TrimSpace(body)
	if len(trim) > 0 && trim[0] == '[' {
		var reqs []rpcReq
		if e := json.Unmarshal(trim, &reqs); e != nil {
			return nil, nil, true, e
		}
		var keep []rpcReq
		for _, r := range reqs {
			if p.allow[r.Method] {
				keep = append(keep, r)
			} else {
				denied = append(denied, deny(r.ID, -32601, "method not allowed by rbb-rpc-proxy: "+r.Method))
			}
		}
		if len(keep) == 0 {
			return nil, denied, true, nil
		}
		fwd, _ := json.Marshal(keep)
		return fwd, denied, true, nil
	}
	var r rpcReq
	if e := json.Unmarshal(trim, &r); e != nil {
		return nil, nil, false, e
	}
	if !p.allow[r.Method] {
		return nil, []rpcErr{deny(r.ID, -32601, "method not allowed by rbb-rpc-proxy: "+r.Method)}, false, nil
	}
	return trim, nil, false, nil
}

func (p *proxy) ServeHTTP(w http.ResponseWriter, req *http.Request) {
	w.Header().Set("Content-Type", "application/json")
	if req.Method != http.MethodPost {
		http.Error(w, `{"error":"only POST JSON-RPC"}`, http.StatusMethodNotAllowed)
		return
	}
	body, err := io.ReadAll(io.LimitReader(req.Body, p.maxBody+1))
	if err != nil || int64(len(body)) > p.maxBody {
		writeJSON(w, http.StatusRequestEntityTooLarge, deny(nil, -32600, "request too large"))
		return
	}
	forward, denied, batch, err := p.filter(body)
	if err != nil {
		writeJSON(w, http.StatusBadRequest, deny(nil, -32700, "parse error"))
		return
	}
	var upstreamResp []json.RawMessage
	if forward != nil {
		resp, err := p.client.Post(p.upstream, "application/json", bytes.NewReader(forward))
		if err != nil {
			log.Printf("upstream: %v", err)
			writeJSON(w, http.StatusBadGateway, deny(nil, -32603, "upstream unavailable"))
			return
		}
		defer resp.Body.Close()
		out, _ := io.ReadAll(resp.Body)
		if !batch {
			w.WriteHeader(resp.StatusCode)
			w.Write(out)
			return
		}
		if json.Unmarshal(out, &upstreamResp) != nil { // upstream devolveu objeto único (erro): repassa
			w.WriteHeader(resp.StatusCode)
			w.Write(out)
			return
		}
	}
	if !batch {
		writeJSON(w, http.StatusOK, denied[0])
		return
	}
	all := make([]json.RawMessage, 0, len(upstreamResp)+len(denied))
	all = append(all, upstreamResp...)
	for _, d := range denied {
		b, _ := json.Marshal(d)
		all = append(all, b)
	}
	writeJSON(w, http.StatusOK, all)
}

func writeJSON(w http.ResponseWriter, status int, v any) {
	w.WriteHeader(status)
	json.NewEncoder(w).Encode(v)
}

func env(k, def string) string {
	if v := os.Getenv(k); v != "" {
		return v
	}
	return def
}

func main() {
	allow := defaultAllow
	if v := os.Getenv("ALLOW"); v != "" {
		allow = strings.Split(v, ",")
	}
	maxBody, _ := strconv.ParseInt(env("MAX_BODY", "1048576"), 10, 64)
	p := newProxy(env("UPSTREAM", "http://127.0.0.1:8545"), allow, maxBody)
	mux := http.NewServeMux()
	mux.HandleFunc("/healthz", func(w http.ResponseWriter, _ *http.Request) { w.Write([]byte("ok\n")) })
	mux.Handle("/", p)
	listen := env("LISTEN", ":8546")
	log.Printf("rbb-rpc-proxy: %s -> %s, %d métodos permitidos", listen, p.upstream, len(p.allow))
	log.Fatal(http.ListenAndServe(listen, mux))
}
