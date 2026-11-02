package main

import (
	"fmt"
	"strings"
)

// Eventos do contrato Governance (gen02) e leitura de organizações (Organization) para nomes.
var (
	topicProposalCreated   = topic("ProposalCreated(uint256,address[],bytes[],uint256,string)")
	topicOrganizationVoted = topic("OrganizationVoted(uint256,uint256,bool)")
	topicProposalCanceled  = topic("ProposalCanceled(uint256,string)")
	topicProposalFinished  = topic("ProposalFinished(uint256)")
	topicProposalApproved  = topic("ProposalApproved(uint256)")
	topicProposalRejected  = topic("ProposalRejected(uint256)")
	topicProposalExecuted  = topic("ProposalExecuted(uint256)")
)

type Proposal struct {
	ID             uint64
	ProponentOrg   uint64
	BlocksDuration uint64
	Description    string
	CreationBlock  uint64
	Status         uint64 // 0 Active, 1 Canceled, 2 Finished, 3 Executed
	Result         uint64 // 0 Undefined, 1 Approved, 2 Rejected
	Organizations  []uint64
	Votes          []uint64 // 0 NotVoted, 1 Approval, 2 Rejection (mesma ordem de Organizations)
}

// getProposal(uint256) retorna um struct dinâmico (ProposalData); decodifica os campos que usamos.
func (r *RPC) GetProposal(governance string, id uint64) (*Proposal, error) {
	out, err := r.EthCall(governance, encodeCallUint("getProposal(uint256)", id))
	if err != nil {
		return nil, err
	}
	rd := abiReader{out}
	base, err := rd.uintAt(0) // deslocamento do struct (tupla dinâmica)
	if err != nil {
		return nil, err
	}
	b := int(base)
	p := &Proposal{}
	if p.ID, err = rd.uintAt(b + 0*32); err != nil {
		return nil, err
	}
	p.ProponentOrg, _ = rd.uintAt(b + 1*32)
	// 2: targets (dyn) 3: calldatas (dyn)
	p.BlocksDuration, _ = rd.uintAt(b + 4*32)
	p.Description, _ = rd.stringAt(b, b+5*32)
	p.CreationBlock, _ = rd.uintAt(b + 6*32)
	p.Status, _ = rd.uintAt(b + 7*32)
	p.Result, _ = rd.uintAt(b + 8*32)
	p.Organizations, _ = rd.uintArrayAt(b, b+9*32)
	votes, _ := rd.uintArrayAt(b, b+10*32) // array de enum = uint8[] codificado como uint256[]
	p.Votes = votes
	return p, nil
}

func (p *Proposal) Tally() (approve, reject, pending int) {
	for _, v := range p.Votes {
		switch v {
		case 1:
			approve++
		case 2:
			reject++
		default:
			pending++
		}
	}
	return
}

// Organization.getOrganization(uint256) -> (id, cnpj, name, orgType, canVote)
type Org struct {
	ID      uint64
	Name    string
	CanVote bool
}

func (r *RPC) GetOrganization(organization string, id uint64) (*Org, error) {
	out, err := r.EthCall(organization, encodeCallUint("getOrganization(uint256)", id))
	if err != nil {
		return nil, err
	}
	rd := abiReader{out}
	base, err := rd.uintAt(0)
	if err != nil {
		return nil, err
	}
	b := int(base)
	o := &Org{}
	o.ID, _ = rd.uintAt(b + 0*32)
	o.Name, _ = rd.stringAt(b, b+2*32)
	o.CanVote, _ = rd.bool(b + 4*32)
	if o.Name == "" {
		return nil, fmt.Errorf("organização %d sem nome", id)
	}
	return o, nil
}

// Nome de organização com cache; cai no id quando o contrato Organization não foi configurado
func (b *Bot) orgName(id uint64) string {
	if n, ok := b.state.OrgNames[id]; ok {
		return n
	}
	if b.cfg.OrganizationAddr != "" {
		if o, err := b.rpc.GetOrganization(b.cfg.OrganizationAddr, id); err == nil {
			b.state.OrgNames[id] = o.Name
			return o.Name
		}
	}
	return fmt.Sprintf("org %d", id)
}

func statusText(p *Proposal) string {
	switch p.Status {
	case 1:
		return "cancelada"
	case 2:
		if p.Result == 1 {
			return "aprovada"
		}
		return "rejeitada"
	case 3:
		return "executada"
	}
	return "em votação"
}

func firstLine(s string) string {
	if i := strings.IndexAny(s, "\r\n"); i >= 0 {
		s = s[:i]
	}
	if len(s) > 120 {
		s = s[:117] + "…"
	}
	return s
}
