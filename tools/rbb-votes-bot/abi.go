package main

import (
	"encoding/hex"
	"errors"
	"math/big"
	"strings"

	"golang.org/x/crypto/sha3"
)

func keccak(b []byte) []byte {
	h := sha3.NewLegacyKeccak256()
	h.Write(b)
	return h.Sum(nil)
}

// Seletor de função (4 bytes) e tópico de evento (32 bytes) a partir da assinatura
func selector(sig string) []byte { return keccak([]byte(sig))[:4] }
func topic(sig string) string    { return "0x" + hex.EncodeToString(keccak([]byte(sig))) }

// Decodificador ABI mínimo (uint, bool, address, string, bytes e arrays de uint/address/bytes).
type abiReader struct{ data []byte }

func (r abiReader) word(off int) ([]byte, error) {
	if off < 0 || off+32 > len(r.data) {
		return nil, errors.New("abi: fora dos dados")
	}
	return r.data[off : off+32], nil
}
func (r abiReader) uint(off int) (*big.Int, error) {
	w, err := r.word(off)
	if err != nil {
		return nil, err
	}
	return new(big.Int).SetBytes(w), nil
}
func (r abiReader) uintAt(off int) (uint64, error) {
	n, err := r.uint(off)
	if err != nil {
		return 0, err
	}
	return n.Uint64(), nil
}
func (r abiReader) bool(off int) (bool, error) {
	n, err := r.uintAt(off)
	return n != 0, err
}
func (r abiReader) address(off int) (string, error) {
	w, err := r.word(off)
	if err != nil {
		return "", err
	}
	return "0x" + hex.EncodeToString(w[12:]), nil
}

// dinâmico: no slot "off" está o deslocamento (relativo a base) do conteúdo
func (r abiReader) bytesAt(base, off int) ([]byte, error) {
	p, err := r.uintAt(off)
	if err != nil {
		return nil, err
	}
	start := base + int(p)
	l, err := r.uintAt(start)
	if err != nil {
		return nil, err
	}
	if start+32+int(l) > len(r.data) {
		return nil, errors.New("abi: bytes fora dos dados")
	}
	return r.data[start+32 : start+32+int(l)], nil
}
func (r abiReader) stringAt(base, off int) (string, error) {
	b, err := r.bytesAt(base, off)
	return string(b), err
}
func (r abiReader) uintArrayAt(base, off int) ([]uint64, error) {
	p, err := r.uintAt(off)
	if err != nil {
		return nil, err
	}
	start := base + int(p)
	n, err := r.uintAt(start)
	if err != nil {
		return nil, err
	}
	out := make([]uint64, 0, n)
	for i := 0; i < int(n); i++ {
		v, err := r.uintAt(start + 32 + i*32)
		if err != nil {
			return nil, err
		}
		out = append(out, v)
	}
	return out, nil
}

// Codificação de chamada: seletor + uint256
func encodeCallUint(sig string, v uint64) []byte {
	b := make([]byte, 32)
	new(big.Int).SetUint64(v).FillBytes(b)
	return append(selector(sig), b...)
}

func shortAddr(a string) string {
	a = strings.ToLower(a)
	if len(a) > 10 {
		return a[:10] + "…"
	}
	return a
}
