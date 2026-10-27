package main

import (
	"encoding/hex"
	"fmt"
	"math/big"
	"strings"
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

// Placar QBFT: voto conta uma vez, reemissão após a época não é "retirada", troca de voto e maioria
func TestVoteTally(t *testing.T) {
	b := &Bot{cfg: Config{Network: "T", EpochLength: 100}, state: loadState("/nonexistent/state.json"), names: map[string]string{}}
	for i := 1; i <= 9; i++ {
		b.state.Validators = append(b.state.Validators, fmt.Sprintf("0x%040x", i))
	}
	cand := "0x" + strings.Repeat("be", 20)
	drop := &HeaderVote{Candidate: cand, Add: false}
	p1 := b.state.Validators[0]

	msgs := b.applyVote(10, p1, drop)
	if len(msgs) != 1 || !strings.Contains(msgs[0], "vota **REMOVER**") || !strings.Contains(msgs[0], "1 de 5") {
		t.Fatalf("primeiro voto: %v", msgs)
	}
	if msgs := b.applyVote(19, p1, drop); msgs != nil {
		t.Fatalf("voto repetido não deve gerar mensagem: %v", msgs)
	}
	// bloco de época zera; a reemissão é informada como manutenção do voto, não como voto novo
	b.newEpoch(100)
	if b.state.count("drop:"+cand) != 0 {
		t.Fatal("época deveria zerar o placar")
	}
	msgs = b.applyVote(109, p1, drop)
	if len(msgs) != 0 || b.state.count("drop:"+cand) != 1 {
		t.Fatalf("reemissão após época deve ser contada em silêncio: %v %v", msgs, b.state.Tally)
	}
	// troca de voto
	msgs = b.applyVote(118, p1, &HeaderVote{Candidate: cand, Add: true})
	if len(msgs) != 1 || !strings.Contains(msgs[0], "muda o voto") || b.state.count("drop:"+cand) != 0 || b.state.count("add:"+cand) != 1 {
		t.Fatalf("troca de voto: %v %v", msgs, b.state.Tally)
	}
	// maioria: 5 de 9
	for i := 1; i < 5; i++ {
		msgs = b.applyVote(uint64(120+i), b.state.Validators[i], &HeaderVote{Candidate: cand, Add: true})
	}
	if len(msgs) != 2 || !strings.Contains(msgs[0], "5 de 5") || !strings.Contains(msgs[1], "maioria atingida") || len(b.state.Tally) != 0 {
		t.Fatalf("maioria: %v %v", msgs, b.state.Tally)
	}
}
