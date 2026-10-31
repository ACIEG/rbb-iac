// rbb-votes-bot: acompanha as votações da RBB e avisa num canal do Discord.
//   - Votações QBFT (entrada/saída de validators), lidas nos cabeçalhos dos blocos.
//   - Propostas de governança gen02 (contrato Governance), lidas nos eventos e por getProposal.
//
// Só leitura, só fatos: quem votou em quem, placar, prazo, mudanças no conjunto de validators.
package main

import (
	"encoding/json"
	"flag"
	"fmt"
	"log"
	"os"
	"sort"
	"strings"
	"time"
)

type Config struct {
	RPCURL           string
	GovernanceAddr   string
	OrganizationAddr string
	NodesJSON        string // participantes/<rede>/nodes.json: nomes dos validators
	OrgName          string // nossa organização (para avisos no canal próprio)
	WebhookNetwork   string
	WebhookOrg       string
	WebhookIncidents string // rascunhos de issue (vazio = canal da organização, senão o da rede)
	StallAfter       time.Duration
	StateFile        string
	Poll             time.Duration
	BotName          string
	Network          string
	DeadlineWarn     time.Duration // aviso de prazo antes de vencer
	EpochLength      uint64        // qbft.epochlength do genesis: a contagem de votos zera nesses blocos
}

type Bot struct {
	cfg   Config
	rpc   *RPC
	state *State
	names map[string]string // endereço do validator (minúsculo) -> "ORG/validator01"

	pendingIncidents [][2]string // rascunhos de incidente a publicar depois das mensagens do bloco
	lastIncident     string      // último rascunho publicado (testes)
}

func env(k, def string) string {
	if v := os.Getenv(k); v != "" {
		return v
	}
	return def
}

func envUint(k string, def uint64) uint64 {
	if v := os.Getenv(k); v != "" {
		var n uint64
		if _, err := fmt.Sscan(v, &n); err == nil {
			return n
		}
	}
	return def
}

func main() {
	var cfg Config
	flag.StringVar(&cfg.RPCURL, "rpc", env("RPC_URL", "http://127.0.0.1:8545"), "URL JSON-RPC de um nó da rede")
	flag.StringVar(&cfg.GovernanceAddr, "governance", env("GOVERNANCE_ADDRESS", ""), "endereço do contrato Governance (gen02)")
	flag.StringVar(&cfg.OrganizationAddr, "organization", env("ORGANIZATION_ADDRESS", ""), "endereço do contrato Organization (nomes)")
	flag.StringVar(&cfg.NodesJSON, "nodes", env("NODES_JSON", ""), "nodes.json do participantes (nomes dos validators)")
	flag.StringVar(&cfg.OrgName, "org", env("ORG_NAME", ""), "nossa organização, como no nodes.json")
	flag.StringVar(&cfg.WebhookNetwork, "webhook-network", env("DISCORD_WEBHOOK_NETWORK", ""), "webhook do canal da rede (vazio = só log)")
	flag.StringVar(&cfg.WebhookOrg, "webhook-org", env("DISCORD_WEBHOOK_ORG", ""), "webhook do canal da organização (vazio = só log)")
	flag.StringVar(&cfg.WebhookIncidents, "webhook-incidents", env("DISCORD_WEBHOOK_INCIDENTS", ""), "webhook para rascunhos de issue de incidentes (vazio = canal da organização, senão o da rede)")
	stall := flag.Duration("stall-after", 3*time.Minute, "tempo sem bloco novo para considerar a rede parada")
	flag.StringVar(&cfg.StateFile, "state", env("STATE_FILE", "/var/lib/rbb-votes-bot/state.json"), "arquivo de estado")
	flag.StringVar(&cfg.BotName, "name", env("BOT_NAME", "RBB votações"), "nome exibido no Discord")
	flag.StringVar(&cfg.Network, "network", env("RBB_NETWORK", "TESTNET"), "nome da rede nas mensagens")
	poll := flag.Duration("poll", 30*time.Second, "intervalo entre leituras")
	warn := flag.Duration("deadline-warn", 24*time.Hour, "aviso de prazo das propostas antes de vencer")
	epoch := flag.Uint64("epoch", envUint("EPOCH_LENGTH", 30000), "qbft.epochlength do genesis (0 = sem época)")
	once := flag.Bool("once", false, "executa uma varredura e sai")
	flag.Parse()
	cfg.Poll, cfg.DeadlineWarn, cfg.EpochLength, cfg.StallAfter = *poll, *warn, *epoch, *stall

	b := &Bot{cfg: cfg, rpc: NewRPC(cfg.RPCURL), state: loadState(cfg.StateFile), names: loadNames(cfg.NodesJSON)}
	log.Printf("rbb-votes-bot: rpc=%s governance=%s estado=%s (bloco %d)", cfg.RPCURL, cfg.GovernanceAddr, cfg.StateFile, b.state.LastBlock)
	for {
		if err := b.tick(); err != nil {
			log.Printf("erro: %v", err)
		}
		if err := b.state.save(cfg.StateFile); err != nil {
			log.Printf("estado: %v", err)
		}
		if *once {
			return
		}
		time.Sleep(cfg.Poll)
	}
}

// Nomes dos validators a partir do nodes.json (campo id = endereço do validator)
func loadNames(path string) map[string]string {
	names := map[string]string{}
	if path == "" {
		return names
	}
	raw, err := os.ReadFile(path)
	if err != nil {
		log.Printf("nodes.json: %v (mensagens usarão endereços)", err)
		return names
	}
	var orgs []struct {
		Organization string `json:"organization"`
		Nodes        []struct {
			Name     string `json:"name"`
			NodeType string `json:"nodeType"`
			ID       string `json:"id"`
		} `json:"nodes"`
	}
	if err := json.Unmarshal(raw, &orgs); err != nil {
		log.Printf("nodes.json: %v", err)
		return names
	}
	for _, o := range orgs {
		for _, n := range o.Nodes {
			if n.ID != "" {
				names[strings.ToLower(n.ID)] = o.Organization + "/" + n.Name
			}
		}
	}
	return names
}

func (b *Bot) name(addr string) string {
	addr = strings.ToLower(addr)
	if n, ok := b.names[addr]; ok {
		return n
	}
	if n, ok := b.names["0x"+strings.TrimPrefix(addr, "0x")]; ok {
		return n
	}
	return shortAddr(addr)
}

func (b *Bot) orgOf(addr string) string {
	n := b.name(addr)
	if i := strings.Index(n, "/"); i > 0 {
		return n[:i]
	}
	return n
}

func (b *Bot) tick() error {
	head, err := b.rpc.BlockNumber()
	if err != nil {
		return err
	}
	if b.state.LastBlock == 0 {
		b.state.LastBlock = head - 1 // primeira execução: começa do presente
		b.state.LastGovBlock = head - 1
	}
	b.checkStall(head)
	if head <= b.state.LastBlock {
		return nil
	}
	// não varre um abismo após parada longa: retoma dos últimos 2000 blocos
	from := b.state.LastBlock + 1
	if head-from > 2000 {
		from = head - 2000
	}
	for n := from; n <= head; n++ {
		if err := b.processBlock(n); err != nil {
			return fmt.Errorf("bloco %d: %w", n, err)
		}
		b.state.LastBlock = n
	}
	if err := b.checkValidators(head); err != nil {
		return err
	}
	if b.cfg.GovernanceAddr != "" {
		if err := b.checkGovernance(head); err != nil {
			return err
		}
	}
	return nil
}

// Votos QBFT embutidos nos cabeçalhos. O Besu mantém um placar (VoteTally) por época:
// cada validator emite o voto UMA vez (no primeiro bloco que propõe depois de registrá-lo), o voto fica
// contado até atingir maioria, até o candidato mudar de situação ou até o bloco de época, quando tudo zera.
// Um bloco sem voto não significa que o validator desistiu: o voto já foi contado. O bot espelha esse placar.
func (b *Bot) processBlock(n uint64) error {
	if b.cfg.EpochLength > 0 && n%b.cfg.EpochLength == 0 {
		b.newEpoch(n)
		return nil // o Besu ignora qualquer voto embutido no bloco de época
	}
	blk, err := b.rpc.Block(n)
	if err != nil {
		return err
	}
	v, err := decodeHeaderVote(blk.ExtraData)
	if err != nil || v == nil {
		return nil // sem extraData QBFT ou sem voto
	}
	msgs := b.applyVote(n, strings.ToLower(blk.Miner), v)
	for _, msg := range msgs {
		b.postNetwork(msg)
	}
	b.flushIncidents()
	if len(msgs) > 0 && b.cfg.OrgName != "" && strings.EqualFold(b.orgOf(v.Candidate), b.cfg.OrgName) {
		verb := "adicionar"
		if !v.Add {
			verb = "remover"
		}
		b.postOrg(fmt.Sprintf("👀 %s: a **%s** votou para **%s** o nosso validator (%d de %d).", b.cfg.Network, b.orgOf(blk.Miner), verb, b.state.count(voteKey(v)), b.majority()))
	}
	return nil
}

func voteKey(v *HeaderVote) string {
	if v.Add {
		return "add:" + v.Candidate
	}
	return "drop:" + v.Candidate
}

func opposite(key string) string {
	kind, cand := splitVote(key)
	if kind == "add" {
		return "drop:" + cand
	}
	return "add:" + cand
}

// Aplica um voto ao placar como o VoteTally.addVote do Besu e devolve as mensagens a publicar
func (b *Bot) applyVote(n uint64, proposer string, v *HeaderVote) []string {
	key := voteKey(v)
	if b.state.has(key, proposer) {
		return nil // já contado nesta época (o Besu não reemite)
	}
	switched := b.state.remove(opposite(key), proposer)
	b.state.addVote(key, proposer)
	tally, maj := b.state.count(key), b.majority()
	verb := "ADICIONAR"
	if !v.Add {
		verb = "REMOVER"
	}
	var msgs []string
	how := "vota"
	if switched {
		how = "muda o voto e agora vota"
	}
	if !switched && b.state.hadBeforeEpoch(key, proposer) {
		// reemissão do mesmo voto depois da época: não é novidade, não vai para o canal
		log.Printf("bloco %d: %s reemitiu o voto %s (%d de %d)", n, b.orgOf(proposer), b.describeVote(key), tally, maj)
	} else {
		msgs = append(msgs, fmt.Sprintf("🗳️ %s: **%s** %s **%s** o validator **%s** — %d de %d necessários. Bloco %d.",
			b.cfg.Network, b.orgOf(proposer), how, verb, b.name(v.Candidate), tally, maj, n))
	}
	if tally >= maj {
		// maioria: o Besu aplica a mudança já neste bloco e descarta os votos sobre o candidato
		if v.Add {
			b.state.Joined[v.Candidate] = n
		} else {
			b.removalIncident(v.Candidate, append([]string{}, b.state.Tally[key]...), n)
		}
		b.state.discardFor(v.Candidate, !v.Add)
		b.state.setValidator(v.Candidate, v.Add)
		b.state.LastSetChange = n
		msgs = append(msgs, fmt.Sprintf("🔔 %s: maioria atingida para %s **%s**; a mudança no consenso vale a partir do próximo bloco.", b.cfg.Network, strings.ToLower(verb), b.name(v.Candidate)))
		msgs = append(msgs, b.setChangeMessages(v.Candidate, v.Add, n)...)
	}
	return msgs
}

// Mensagens de entrada/saída do consenso (canal da rede e, se for o nosso, da organização)
func (b *Bot) setChangeMessages(cand string, joined bool, n uint64) []string {
	var msgs []string
	if joined {
		msgs = append(msgs, fmt.Sprintf("✅ %s: validator **%s** ENTROU no consenso. Agora são %d validators. Bloco %d.", b.cfg.Network, b.name(cand), len(b.state.Validators), n))
	} else {
		msgs = append(msgs, fmt.Sprintf("⚠️ %s: validator **%s** SAIU do consenso. Agora são %d validators. Bloco %d.", b.cfg.Network, b.name(cand), len(b.state.Validators), n))
	}
	if b.cfg.OrgName != "" && strings.EqualFold(b.orgOf(cand), b.cfg.OrgName) {
		if joined {
			b.postOrg(fmt.Sprintf("🎉 %s: o nosso validator entrou no consenso (bloco %d).", b.cfg.Network, n))
		} else {
			b.postOrg(fmt.Sprintf("🚨 %s: o nosso validator SAIU do consenso (bloco %d). Verifique o nó e peça nova votação.", b.cfg.Network, n))
		}
	}
	return msgs
}

// Bloco de época: o Besu zera o placar; quem ainda tiver a proposta registrada no nó reemite o voto (em silêncio)
func (b *Bot) newEpoch(n uint64) {
	pending := b.state.pendingVotes()
	b.state.PrevEpochTally, b.state.Tally = b.state.Tally, map[string][]string{}
	if len(pending) == 0 {
		return
	}
	var parts []string
	for _, pv := range pending {
		parts = append(parts, fmt.Sprintf("%s (%s)", b.describeVote(pv.key), b.orgList(pv.proposers)))
	}
	b.postNetwork(fmt.Sprintf("🔄 %s: nova época no bloco %d, a contagem de votos QBFT foi zerada. Votos descartados: %s. Quem mantiver a proposta no nó reemite o voto automaticamente.",
		b.cfg.Network, n, strings.Join(parts, "; ")))
}

func (b *Bot) orgList(addrs []string) string {
	var out []string
	for _, a := range addrs {
		out = append(out, b.orgOf(a))
	}
	return strings.Join(out, ", ")
}

func splitVote(s string) (kind, cand string) {
	if i := strings.Index(s, ":"); i > 0 {
		return s[:i], s[i+1:]
	}
	return "", s
}

func (b *Bot) describeVote(s string) string {
	kind, cand := splitVote(s)
	if kind == "drop" {
		return "remover " + b.name(cand)
	}
	return "adicionar " + b.name(cand)
}

func (b *Bot) majority() int { return len(b.state.Validators)/2 + 1 }

// Reconciliação do conjunto de validators com o nó. As mudanças normais são vistas bloco a bloco em
// applyVote (maioria); aqui só entra o que escapou (lacuna de blocos, primeira execução), sem mexer no placar.
func (b *Bot) checkValidators(head uint64) error {
	// qbft_getValidatorsByBlockNumber(head) devolve o conjunto que validou o bloco head, ou seja, sem a
	// mudança decidida no próprio head (ela vale a partir do seguinte). Se acabamos de aplicar uma
	// mudança nesse bloco, o nó ainda responde o conjunto antigo: não há o que reconciliar.
	if b.state.LastSetChange != 0 && head <= b.state.LastSetChange {
		return nil
	}
	vals, err := b.rpc.Validators(head)
	if err != nil {
		return err
	}
	for i := range vals {
		vals[i] = strings.ToLower(vals[i])
	}
	sort.Strings(vals)
	if len(b.state.Validators) == 0 {
		b.state.Validators = vals
		return nil
	}
	old := map[string]bool{}
	for _, v := range b.state.Validators {
		old[v] = true
	}
	cur := map[string]bool{}
	for _, v := range vals {
		cur[v] = true
	}
	var msgs []string
	for _, v := range vals {
		if !old[v] {
			b.state.Validators = vals
			msgs = append(msgs, b.setChangeMessages(v, true, head)...)
		}
	}
	for _, v := range b.state.Validators {
		if !cur[v] {
			b.state.Validators = vals
			msgs = append(msgs, b.setChangeMessages(v, false, head)...)
			b.state.discardFor(v, true) // quem saiu deixa de contar como eleitor
		}
	}
	b.state.Validators = vals
	for _, m := range msgs {
		b.postNetwork(m)
	}
	return nil
}

// Propostas de governança: eventos novos desde a última leitura + prazos
func (b *Bot) checkGovernance(head uint64) error {
	from := b.state.LastGovBlock + 1
	if head < from {
		return nil
	}
	if head-from > 5000 {
		from = head - 5000
	}
	logs, err := b.rpc.Logs(b.cfg.GovernanceAddr, from, head)
	if err != nil {
		return err
	}
	touched := map[uint64]bool{}
	for _, l := range logs {
		if len(l.Topics) < 2 {
			continue
		}
		id, _ := hexToUint(l.Topics[1])
		touched[id] = true
		switch l.Topics[0] {
		case topicProposalCreated:
			b.onProposalCreated(id, head)
		case topicOrganizationVoted:
			rd := abiReader{}
			rd.data, _ = hexDecode(l.Data)
			org, _ := rd.uintAt(0)
			approve, _ := rd.bool(32)
			b.onVote(id, org, approve)
		case topicProposalCanceled:
			b.onStatus(id, "cancelada")
		case topicProposalApproved:
			b.onStatus(id, "aprovada")
		case topicProposalRejected:
			b.onStatus(id, "rejeitada")
		case topicProposalExecuted:
			b.onStatus(id, "executada")
		}
	}
	b.state.LastGovBlock = head
	// prazos das propostas ativas
	for key, ps := range b.state.Proposals {
		if ps.Status != "em votação" || ps.WarnedDeadline || ps.Deadline == 0 {
			continue
		}
		blocksLeft := int64(ps.Deadline) - int64(head)
		if blocksLeft <= 0 {
			continue
		}
		left := time.Duration(blocksLeft) * b.blockTime()
		if left <= b.cfg.DeadlineWarn {
			ps.WarnedDeadline = true
			msg := fmt.Sprintf("⏳ %s: proposta **%s** (%s) vence em ~%s e está com %d aprovações / %d rejeições. Quem ainda não votou: %s.",
				b.cfg.Network, key, ps.Description, humanDur(left), ps.Approve, ps.Reject, b.pendingOrgs(key))
			b.postNetwork(msg)
			if b.cfg.OrgName != "" && strings.Contains(b.pendingOrgs(key), b.cfg.OrgName) {
				b.postOrg(fmt.Sprintf("⏳ %s: a %s ainda não votou na proposta %s (%s); vence em ~%s. Use governance.js castVote com a conta de Administrador Global.", b.cfg.Network, b.cfg.OrgName, key, ps.Description, humanDur(left)))
			}
		}
	}
	_ = touched
	return nil
}

func (b *Bot) refresh(id uint64) (*Proposal, *PState) {
	key := fmt.Sprint(id)
	p, err := b.rpc.GetProposal(b.cfg.GovernanceAddr, id)
	if err != nil {
		log.Printf("getProposal(%d): %v", id, err)
		return nil, b.state.Proposals[key]
	}
	ps, ok := b.state.Proposals[key]
	if !ok {
		ps = &PState{}
		b.state.Proposals[key] = ps
	}
	ps.Description = firstLine(p.Description)
	ps.Deadline = p.CreationBlock + p.BlocksDuration
	ps.Status = statusText(p)
	ps.Approve, ps.Reject, _ = p.Tally()
	return p, ps
}

func (b *Bot) onProposalCreated(id, head uint64) {
	p, ps := b.refresh(id)
	if p == nil {
		return
	}
	left := time.Duration(int64(ps.Deadline)-int64(head)) * b.blockTime()
	b.postNetwork(fmt.Sprintf("📜 %s: nova proposta de governança **%d** — \"%s\", proposta por **%s**. Vence no bloco %d (~%s). Precisa da maioria de %d organizações votantes.",
		b.cfg.Network, id, ps.Description, b.orgName(p.ProponentOrg), ps.Deadline, humanDur(left), len(p.Organizations)))
	if b.cfg.OrgName != "" {
		b.postOrg(fmt.Sprintf("📜 %s: proposta **%d** criada (\"%s\"); a %s precisa votar até ~%s: `node governance.js getProposal %d` e `castVote %d true|false`.", b.cfg.Network, id, ps.Description, b.cfg.OrgName, humanDur(left), id, id))
	}
}

func (b *Bot) onVote(id, org uint64, approve bool) {
	_, ps := b.refresh(id)
	verb := "APROVOU"
	if !approve {
		verb = "REJEITOU"
	}
	desc := ""
	if ps != nil {
		desc = fmt.Sprintf(" (%s) — %d aprovações / %d rejeições", ps.Description, ps.Approve, ps.Reject)
	}
	b.postNetwork(fmt.Sprintf("🗳️ %s: **%s** %s a proposta **%d**%s.", b.cfg.Network, b.orgName(org), verb, id, desc))
}

func (b *Bot) onStatus(id uint64, status string) {
	_, ps := b.refresh(id)
	desc := ""
	if ps != nil {
		desc = " (" + ps.Description + ")"
		ps.Status = status
	}
	icon := map[string]string{"cancelada": "🚫", "aprovada": "✅", "rejeitada": "❌", "executada": "🏁"}[status]
	b.postNetwork(fmt.Sprintf("%s %s: proposta **%d**%s foi **%s**.", icon, b.cfg.Network, id, desc, status))
}

func (b *Bot) pendingOrgs(key string) string {
	var id uint64
	fmt.Sscan(key, &id)
	p, err := b.rpc.GetProposal(b.cfg.GovernanceAddr, id)
	if err != nil {
		return "?"
	}
	var out []string
	for i, org := range p.Organizations {
		if i < len(p.Votes) && p.Votes[i] == 0 {
			out = append(out, b.orgName(org))
		}
	}
	if len(out) == 0 {
		return "ninguém"
	}
	return strings.Join(out, ", ")
}

// Tempo médio por bloco (medido nos últimos 100 blocos; 4 s se falhar)
func (b *Bot) blockTime() time.Duration {
	head, err := b.rpc.BlockNumber()
	if err != nil || head < 101 {
		return 4 * time.Second
	}
	a, err1 := b.rpc.Block(head)
	c, err2 := b.rpc.Block(head - 100)
	if err1 != nil || err2 != nil {
		return 4 * time.Second
	}
	ta, _ := hexToUint(a.Timestamp)
	tc, _ := hexToUint(c.Timestamp)
	if ta <= tc {
		return 4 * time.Second
	}
	return time.Duration(ta-tc) * time.Second / 100
}

func humanDur(d time.Duration) string {
	if d < time.Hour {
		return fmt.Sprintf("%d min", int(d.Minutes()))
	}
	if d < 48*time.Hour {
		return fmt.Sprintf("%d h", int(d.Hours()))
	}
	return fmt.Sprintf("%d dias", int(d.Hours()/24))
}
