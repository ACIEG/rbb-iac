package main

import (
	"encoding/hex"
	"errors"
	"fmt"
	"strings"
)

// Decodificação RLP mínima do extraData de blocos QBFT (Besu):
//   [vanity, validators, vote, round, seals]   vote = [] ou [recipient(20 bytes), type(0xff adiciona / 0x00 remove)]

type rlpItem struct {
	bytes []byte
	list  []rlpItem
}

func rlpDecode(b []byte, i int) (rlpItem, int, error) {
	if i >= len(b) {
		return rlpItem{}, i, errors.New("rlp truncado")
	}
	x := int(b[i])
	switch {
	case x < 0x80:
		return rlpItem{bytes: b[i : i+1]}, i + 1, nil
	case x < 0xb8:
		l := x - 0x80
		return rlpItem{bytes: b[i+1 : i+1+l]}, i + 1 + l, nil
	case x < 0xc0:
		ll := x - 0xb7
		l := beInt(b[i+1 : i+1+ll])
		s := i + 1 + ll
		return rlpItem{bytes: b[s : s+l]}, s + l, nil
	case x < 0xf8:
		l := x - 0xc0
		return rlpList(b, i+1, i+1+l)
	default:
		ll := x - 0xf7
		l := beInt(b[i+1 : i+1+ll])
		s := i + 1 + ll
		return rlpList(b, s, s+l)
	}
}

func rlpList(b []byte, s, end int) (rlpItem, int, error) {
	if end > len(b) {
		return rlpItem{}, s, errors.New("rlp truncado")
	}
	var out []rlpItem
	for s < end {
		it, n, err := rlpDecode(b, s)
		if err != nil {
			return rlpItem{}, n, err
		}
		out = append(out, it)
		s = n
	}
	return rlpItem{list: out}, end, nil
}

func beInt(b []byte) int {
	n := 0
	for _, c := range b {
		n = n<<8 | int(c)
	}
	return n
}

func hexDecode(s string) ([]byte, error) { return hex.DecodeString(strings.TrimPrefix(s, "0x")) }

// Vote embutido no cabeçalho: candidato (0x...) e se é adição
type HeaderVote struct {
	Candidate string
	Add       bool
}

func decodeHeaderVote(extraData string) (*HeaderVote, error) {
	b, err := hexDecode(extraData)
	if err != nil {
		return nil, err
	}
	it, _, err := rlpDecode(b, 0)
	if err != nil {
		return nil, err
	}
	if it.list == nil || len(it.list) < 3 {
		return nil, fmt.Errorf("extraData não é QBFT")
	}
	vote := it.list[2]
	if vote.list == nil || len(vote.list) != 2 {
		return nil, nil // sem voto
	}
	cand := "0x" + hex.EncodeToString(vote.list[0].bytes)
	t := vote.list[1].bytes
	add := len(t) == 1 && t[0] == 0xff
	return &HeaderVote{Candidate: strings.ToLower(cand), Add: add}, nil
}
