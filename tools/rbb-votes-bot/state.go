package main

import (
	"encoding/json"
	"os"
)

// Estado persistido entre execuções: evita repetir mensagens e permite retomar de onde parou.
type State struct {
	LastBlock    uint64             `json:"lastBlock"`
	Validators   []string           `json:"validators"`  // conjunto QBFT conhecido
	HeaderVotes  map[string]string  `json:"headerVotes"` // proposer -> "add:0x..." / "drop:0x..."
	Proposals    map[string]*PState `json:"proposals"`   // id -> estado conhecido
	OrgNames     map[uint64]string  `json:"orgNames"`
	LastGovBlock uint64             `json:"lastGovBlock"`
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
	s := &State{HeaderVotes: map[string]string{}, Proposals: map[string]*PState{}, OrgNames: map[uint64]string{}}
	if b, err := os.ReadFile(path); err == nil {
		json.Unmarshal(b, s)
	}
	if s.HeaderVotes == nil {
		s.HeaderVotes = map[string]string{}
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
