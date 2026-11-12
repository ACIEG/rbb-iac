package main

import (
	"encoding/json"
	"io"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
)

func upstream(t *testing.T) *httptest.Server {
	return httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		body, _ := io.ReadAll(r.Body)
		if strings.HasPrefix(strings.TrimSpace(string(body)), "[") {
			var reqs []rpcReq
			json.Unmarshal(body, &reqs)
			var out []map[string]any
			for _, q := range reqs {
				out = append(out, map[string]any{"jsonrpc": "2.0", "id": json.RawMessage(q.ID), "result": q.Method})
			}
			json.NewEncoder(w).Encode(out)
			return
		}
		var q rpcReq
		json.Unmarshal(body, &q)
		json.NewEncoder(w).Encode(map[string]any{"jsonrpc": "2.0", "id": json.RawMessage(q.ID), "result": q.Method})
	}))
}

func call(t *testing.T, srv *httptest.Server, body string) (int, string) {
	resp, err := http.Post(srv.URL, "application/json", strings.NewReader(body))
	if err != nil {
		t.Fatal(err)
	}
	defer resp.Body.Close()
	b, _ := io.ReadAll(resp.Body)
	return resp.StatusCode, string(b)
}

func TestAllowAndDeny(t *testing.T) {
	up := upstream(t)
	defer up.Close()
	srv := httptest.NewServer(newProxy(up.URL, defaultAllow, 1<<20))
	defer srv.Close()

	if _, out := call(t, srv, `{"jsonrpc":"2.0","id":1,"method":"eth_blockNumber","params":[]}`); !strings.Contains(out, `"result":"eth_blockNumber"`) {
		t.Fatalf("método permitido não encaminhado: %s", out)
	}
	for _, m := range []string{"admin_peers", "debug_traceTransaction", "txpool_besuTransactions", "perm_addAccountsToAllowlist", "eth_sendTransaction", "eth_accounts", "qbft_proposeValidatorVote"} {
		_, out := call(t, srv, `{"jsonrpc":"2.0","id":7,"method":"`+m+`","params":[]}`)
		if !strings.Contains(out, `-32601`) || !strings.Contains(out, `"id":7`) {
			t.Fatalf("%s deveria ser recusado com -32601 e o mesmo id: %s", m, out)
		}
	}
	// lote misto: permitidos encaminhados, recusados respondidos localmente
	_, out := call(t, srv, `[{"jsonrpc":"2.0","id":1,"method":"eth_chainId"},{"jsonrpc":"2.0","id":2,"method":"admin_peers"},{"jsonrpc":"2.0","id":3,"method":"net_version"}]`)
	var arr []map[string]any
	if err := json.Unmarshal([]byte(out), &arr); err != nil || len(arr) != 3 {
		t.Fatalf("lote deveria devolver 3 respostas: %s", out)
	}
	n := 0
	for _, r := range arr {
		if _, bad := r["error"]; bad {
			n++
		}
	}
	if n != 1 {
		t.Fatalf("lote deveria ter exatamente 1 recusa: %s", out)
	}
	// lote só com recusados: nada vai ao upstream
	_, out = call(t, srv, `[{"jsonrpc":"2.0","id":9,"method":"admin_nodeInfo"}]`)
	if !strings.Contains(out, "-32601") {
		t.Fatalf("lote recusado: %s", out)
	}
	if code, _ := call(t, srv, `not json`); code != http.StatusBadRequest {
		t.Fatalf("corpo inválido deveria dar 400, deu %d", code)
	}
}

func TestCustomAllow(t *testing.T) {
	up := upstream(t)
	defer up.Close()
	srv := httptest.NewServer(newProxy(up.URL, []string{"eth_chainId"}, 1<<20))
	defer srv.Close()
	if _, out := call(t, srv, `{"jsonrpc":"2.0","id":1,"method":"eth_blockNumber"}`); !strings.Contains(out, "-32601") {
		t.Fatalf("fora da lista personalizada deveria ser recusado: %s", out)
	}
}
