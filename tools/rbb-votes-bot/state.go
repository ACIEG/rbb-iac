package main

import (
	"encoding/json"
	"os"
	"sort"
)

// Estado persistido entre execuções: evita repetir mensagens e permite retomar de onde parou.
type State struct {
	LastBlock      uint64              `json:"lastBlock"`
	Validators     []string            `json:"validators"`     // conjunto QBFT conhecido
	Tally          map[string][]string `json:"tally"`          // "add:0x..."/"drop:0x..." -> validators que votaram nesta época
	PrevEpochTally map[string][]string `json:"prevEpochTally"` // placar descartado na última troca de época
	Proposals      map[string]*PState  `json:"proposals"`      // id -> estado conhecido
	OrgNames       map[uint64]string   `json:"orgNames"`
	LastGovBlock   uint64              `json:"lastGovBlock"`
}

type PState struct {
	Description    string `json:"description"`
	Deadline       uint64 `json:"deadline"`
	Status         string `json:"status"`
	Approve        int    `json:"approve"`
	Reject         int    `json:"reject"`
	WarnedDeadline bool   `json:"warnedDeadline"`
	WarnedOrg      bool   `json:"warnedOrg"`
}

func loadState(path string) *State {
	s := &State{Tally: map[string][]string{}, Proposals: map[string]*PState{}, OrgNames: map[uint64]string{}}
	if b, err := os.ReadFile(path); err == nil {
		json.Unmarshal(b, s)
	}
	if s.Tally == nil {
		s.Tally = map[string][]string{}
	}
	if s.Proposals == nil {
		s.Proposals = map[string]*PState{}
	}
	if s.OrgNames == nil {
		s.OrgNames = map[uint64]string{}
	}
	return s
}

func (s *State) save(path string) error {
	b, _ := json.MarshalIndent(s, "", " ")
	tmp := path + ".tmp"
	if err := os.WriteFile(tmp, b, 0o644); err != nil {
		return err
	}
	return os.Rename(tmp, path)
}

// Placar de votos QBFT, espelhando o VoteTally do Besu

func (s *State) has(key, proposer string) bool {
	for _, p := range s.Tally[key] {
		if p == proposer {
			return true
		}
	}
	return false
}

func (s *State) hadBeforeEpoch(key, proposer string) bool {
	for _, p := range s.PrevEpochTally[key] {
		if p == proposer {
			return true
		}
	}
	return false
}

func (s *State) addVote(key, proposer string) {
	if !s.has(key, proposer) {
		s.Tally[key] = append(s.Tally[key], proposer)
	}
}

// remove tira o eleitor do voto indicado; devolve true se ele estava lá
func (s *State) remove(key, proposer string) bool {
	var out []string
	found := false
	for _, p := range s.Tally[key] {
		if p == proposer {
			found = true
			continue
		}
		out = append(out, p)
	}
	if len(out) == 0 {
		delete(s.Tally, key)
	} else {
		s.Tally[key] = out
	}
	return found
}

func (s *State) count(key string) int { return len(s.Tally[key]) }

// discardFor descarta os votos sobre um candidato; se ele saiu do consenso, também deixa de contar como eleitor
func (s *State) discardFor(candidate string, left bool) {
	delete(s.Tally, "add:"+candidate)
	delete(s.Tally, "drop:"+candidate)
	if left {
		for key := range s.Tally {
			s.remove(key, candidate)
		}
	}
}

type pendingVote struct {
	key       string
	proposers []string
}

func (s *State) pendingVotes() []pendingVote {
	var out []pendingVote
	for key, ps := range s.Tally {
		if len(ps) > 0 {
			out = append(out, pendingVote{key, append([]string{}, ps...)})
		}
	}
	sort.Slice(out, func(i, j int) bool { return out[i].key < out[j].key })
	return out
}
