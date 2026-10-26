// rbb-keygen: chave de nó Besu (secp256k1) estável para o provedor Kubernetes, usada como
// "external data source" do OpenTofu. Lê JSON {"name": "...", "dir": "..."} na entrada e devolve
// {"private": "0x…", "public": "0x…" (64 bytes), "address": "0x…", "enode_id": "…"}.
// A chave é gravada em <dir>/<name>.key (0600) na primeira execução e reutilizada depois, para que
// o enode do nó não mude a cada plan/apply. Guarde esse diretório fora do git (ou num cofre).
package main

import (
	"crypto/rand"
	"encoding/hex"
	"encoding/json"
	"fmt"
	"os"
	"path/filepath"
	"strings"

	"github.com/decred/dcrd/dcrec/secp256k1/v4"
	"golang.org/x/crypto/sha3"
)

type in struct {
	Name string `json:"name"`
	Dir  string `json:"dir"`
}

func main() {
	var q in
	if err := json.NewDecoder(os.Stdin).Decode(&q); err != nil || q.Name == "" {
		fail("entrada inválida: esperado {\"name\": ..., \"dir\": ...}")
	}
	if q.Dir == "" {
		q.Dir = "keys"
	}
	if err := os.MkdirAll(q.Dir, 0o700); err != nil {
		fail(err.Error())
	}
	path := filepath.Join(q.Dir, q.Name+".key")
	var priv *secp256k1.PrivateKey
	if b, err := os.ReadFile(path); err == nil {
		raw, err := hex.DecodeString(strings.TrimPrefix(strings.TrimSpace(string(b)), "0x"))
		if err != nil || len(raw) != 32 {
			fail("chave existente inválida em " + path)
		}
		priv = secp256k1.PrivKeyFromBytes(raw)
	} else {
		var err error
		priv, err = secp256k1.GeneratePrivateKeyFromRand(rand.Reader)
		if err != nil {
			fail(err.Error())
		}
		if err := os.WriteFile(path, []byte("0x"+hex.EncodeToString(priv.Serialize())+"\n"), 0o600); err != nil {
			fail(err.Error())
		}
	}
	pub := priv.PubKey().SerializeUncompressed()[1:] // 64 bytes (sem o prefixo 0x04)
	h := sha3.NewLegacyKeccak256()
	h.Write(pub)
	addr := h.Sum(nil)[12:]
	out := map[string]string{
		"private":  "0x" + hex.EncodeToString(priv.Serialize()),
		"public":   "0x" + hex.EncodeToString(pub),
		"enode_id": hex.EncodeToString(pub),
		"address":  "0x" + hex.EncodeToString(addr),
	}
	json.NewEncoder(os.Stdout).Encode(out)
}

func fail(msg string) {
	fmt.Fprintln(os.Stderr, "rbb-keygen:", msg)
	os.Exit(1)
}
