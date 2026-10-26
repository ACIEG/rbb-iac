package main

import (
	"encoding/hex"
	"math/big"
	"testing"
	"time"
)

// Codificador RLP mínimo para montar extraData de teste
func rlpBytes(b []byte) []byte {
	if len(b) == 1 && b[0] < 0x80 {
		return b
	}
	if len(b) < 56 {
		return append([]byte{byte(0x80 + len(b))}, b...)
	}
	l := big.NewInt(int64(len(b))).Bytes()
	return append(append([]byte{byte(0xb7 + len(l))}, l...), b...)
}
func rlpListEnc(items ...[]byte) []byte {
	var body []byte
	for _, it := range items {
		body = append(body, it...)
	}
	if len(body) < 56 {
		return append([]byte{byte(0xc0 + len(body))}, body...)
	}
	l := big.NewInt(int64(len(body))).Bytes()
	return append(append([]byte{byte(0xf7 + len(l))}, l...), body...)
}

func TestDecodeHeaderVote(t *testing.T) {
	vanity := make([]byte, 32)
	val := make([]byte, 20)
	val[19] = 1
	cand := make([]byte, 20)
	cand[0] = 0xbe
	validators := rlpListEnc(rlpBytes(val))
	withVote := rlpListEnc(rlpBytes(vanity), validators, rlpListEnc(rlpBytes(cand), rlpBytes([]byte{0xff})), rlpBytes([]byte{0}), rlpListEnc())
	v, err := decodeHeaderVote("0x" + hex.EncodeToString(withVote))
	if err != nil || v == nil || !v.Add || v.Candidate != "0x"+hex.EncodeToString(cand) {
		t.Fatalf("voto de adição não decodificado: %+v %v", v, err)
	}
	drop := rlpListEnc(rlpBytes(vanity), validators, rlpListEnc(rlpBytes(cand), rlpBytes([]byte{0})), rlpBytes([]byte{0}), rlpListEnc())
	v, err = decodeHeaderVote("0x" + hex.EncodeToString(drop))
	if err != nil || v == nil || v.Add {
		t.Fatalf("voto de remoção não decodificado: %+v %v", v, err)
	}
	none := rlpListEnc(rlpBytes(vanity), validators, rlpListEnc(), rlpBytes([]byte{0}), rlpListEnc())
	v, err = decodeHeaderVote("0x" + hex.EncodeToString(none))
	if err != nil || v != nil {
		t.Fatalf("bloco sem voto deveria dar nil: %+v %v", v, err)
	}
}

func word(v uint64) []byte { b := make([]byte, 32); new(big.Int).SetUint64(v).FillBytes(b); return b }
func wordStr(s string) []byte {
	b := word(uint64(len(s)))
	pad := (32 - len(s)%32) % 32
	return append(append(b, []byte(s)...), make([]byte, pad)...)
}

func TestABIProposalDecode(t *testing.T) {
	// getProposal -> tupla dinâmica: [offset=32] + struct com 12 campos
	// campos: id, proponentOrgId, targets(dyn), calldatas(dyn), blocksDuration, description(dyn), creationBlock, status, result, organizations(dyn), votes(dyn), cancelationReason(dyn)
	head := 12 * 32
	desc := wordStr("Permissionamento da ACIEG")
	orgs := append(word(3), append(word(1), append(word(2), word(16)...)...)...)
	votes := append(word(3), append(word(1), append(word(0), word(2)...)...)...)
	empty := word(0)
	// deslocamentos (relativos ao início do struct)
	offTargets := head
	offCalldatas := offTargets + 32
	offDesc := offCalldatas + 32
	offOrgs := offDesc + len(desc)
	offVotes := offOrgs + len(orgs)
	offReason := offVotes + len(votes)
	body := append([]byte{}, word(7)...)
	body = append(body, word(1)...)
	body = append(body, word(uint64(offTargets))...)
	body = append(body, word(uint64(offCalldatas))...)
	body = append(body, word(60000)...)
	body = append(body, word(uint64(offDesc))...)
	body = append(body, word(21968982)...)
	body = append(body, word(3)...) // Executed
	body = append(body, word(1)...) // Approved
	body = append(body, word(uint64(offOrgs))...)
	body = append(body, word(uint64(offVotes))...)
	body = append(body, word(uint64(offReason))...)
	body = append(body, empty...) // targets vazio
	body = append(body, empty...) // calldatas vazio
	body = append(body, desc...)
	body = append(body, orgs...)
	body = append(body, votes...)
	body = append(body, wordStr("")...)
	data := append(word(32), body...)
	rd := abiReader{data}
	base, _ := rd.uintAt(0)
	b := int(base)
	id, _ := rd.uintAt(b)
	dur, _ := rd.uintAt(b + 4*32)
	d, _ := rd.stringAt(b, b+5*32)
	st, _ := rd.uintAt(b + 7*32)
	o, _ := rd.uintArrayAt(b, b+9*32)
	v, _ := rd.uintArrayAt(b, b+10*32)
	if id != 7 || dur != 60000 || d != "Permissionamento da ACIEG" || st != 3 || len(o) != 3 || o[2] != 16 || len(v) != 3 || v[2] != 2 {
		t.Fatalf("decodificação errada: id=%d dur=%d desc=%q st=%d orgs=%v votes=%v", id, dur, d, st, o, v)
	}
	p := &Proposal{Votes: v}
	a, r, pnd := p.Tally()
	if a != 1 || r != 1 || pnd != 1 {
		t.Fatalf("placar errado: %d %d %d", a, r, pnd)
	}
}

func TestTopicsAndSelector(t *testing.T) {
	if topicOrganizationVoted != "0x"+hex.EncodeToString(keccak([]byte("OrganizationVoted(uint256,uint256,bool)"))) || len(topicOrganizationVoted) != 66 {
		t.Fatal("tópico inconsistente")
	}
	if hex.EncodeToString(selector("getProposal(uint256)")) != hex.EncodeToString(keccak([]byte("getProposal(uint256)"))[:4]) {
		t.Fatal("seletor inconsistente")
	}
}

func TestHumanDur(t *testing.T) {
	if humanDur(30*time.Minute) != "30 min" || humanDur(5*time.Hour) != "5 h" || humanDur(72*time.Hour) != "3 dias" {
		t.Fatal("formatação de duração")
	}
}
