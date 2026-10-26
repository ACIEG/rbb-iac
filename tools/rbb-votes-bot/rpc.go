package main

import (
	"bytes"
	"encoding/json"
	"fmt"
	"math/big"
	"net/http"
	"strings"
	"time"
)

// Cliente JSON-RPC mínimo (só o que o bot usa), sem dependências externas.
type RPC struct {
	URL    string
	Client *http.Client
}

func NewRPC(url string) *RPC { return &RPC{URL: url, Client: &http.Client{Timeout: 20 * time.Second}} }

type rpcResp struct {
	Result json.RawMessage `json:"result"`
	Error  *struct {
		Code    int    `json:"code"`
		Message string `json:"message"`
	} `json:"error"`
}

func (r *RPC) Call(method string, params ...any) (json.RawMessage, error) {
	if params == nil {
		params = []any{}
	}
	body, _ := json.Marshal(map[string]any{"jsonrpc": "2.0", "id": 1, "method": method, "params": params})
	resp, err := r.Client.Post(r.URL, "application/json", bytes.NewReader(body))
	if err != nil {
		return nil, fmt.Errorf("%s: %w", method, err)
	}
	defer resp.Body.Close()
	var out rpcResp
	if err := json.NewDecoder(resp.Body).Decode(&out); err != nil {
		return nil, fmt.Errorf("%s: resposta inválida: %w", method, err)
	}
	if out.Error != nil {
		return nil, fmt.Errorf("%s: %s", method, out.Error.Message)
	}
	return out.Result, nil
}

func hexToUint(s string) (uint64, error) {
	n := new(big.Int)
	if _, ok := n.SetString(strings.TrimPrefix(s, "0x"), 16); !ok {
		return 0, fmt.Errorf("hex inválido: %s", s)
	}
	return n.Uint64(), nil
}

func (r *RPC) BlockNumber() (uint64, error) {
	raw, err := r.Call("eth_blockNumber")
	if err != nil {
		return 0, err
	}
	var s string
	json.Unmarshal(raw, &s)
	return hexToUint(s)
}

type Block struct {
	Number    string `json:"number"`
	Miner     string `json:"miner"`
	ExtraData string `json:"extraData"`
	Timestamp string `json:"timestamp"`
}

func (r *RPC) Block(n uint64) (*Block, error) {
	raw, err := r.Call("eth_getBlockByNumber", fmt.Sprintf("0x%x", n), false)
	if err != nil {
		return nil, err
	}
	var b Block
	if err := json.Unmarshal(raw, &b); err != nil || b.Number == "" {
		return nil, fmt.Errorf("bloco %d indisponível", n)
	}
	return &b, nil
}

func (r *RPC) Validators(n uint64) ([]string, error) {
	raw, err := r.Call("qbft_getValidatorsByBlockNumber", fmt.Sprintf("0x%x", n))
	if err != nil {
		return nil, err
	}
	var v []string
	json.Unmarshal(raw, &v)
	for i := range v {
		v[i] = strings.ToLower(v[i])
	}
	return v, nil
}

type Log struct {
	BlockNumber string   `json:"blockNumber"`
	Topics      []string `json:"topics"`
	Data        string   `json:"data"`
	TxHash      string   `json:"transactionHash"`
}

func (r *RPC) Logs(address string, from, to uint64) ([]Log, error) {
	raw, err := r.Call("eth_getLogs", map[string]any{"address": address, "fromBlock": fmt.Sprintf("0x%x", from), "toBlock": fmt.Sprintf("0x%x", to)})
	if err != nil {
		return nil, err
	}
	var logs []Log
	json.Unmarshal(raw, &logs)
	return logs, nil
}

// eth_call de função view; retorna os bytes ABI do resultado
func (r *RPC) EthCall(to string, data []byte) ([]byte, error) {
	raw, err := r.Call("eth_call", map[string]any{"to": to, "data": "0x" + fmt.Sprintf("%x", data)}, "latest")
	if err != nil {
		return nil, err
	}
	var s string
	json.Unmarshal(raw, &s)
	return hexDecode(s)
}
