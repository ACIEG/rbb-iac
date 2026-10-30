package main

import (
	"fmt"
	"strings"
	"time"
)

// Incidentes: eventos graves ganham, além do aviso normal, um rascunho de issue pronto para colar
// no repositório da RBB, com blocos, horários e envolvidos. Nada é aberto no GitHub automaticamente:
// uma pessoa decide se vale uma issue. Canal: DISCORD_WEBHOOK_INCIDENTS, senão o da organização,
// senão o da rede.
//   - validator removido do consenso (quem votou);
//   - validator removido pouco depois de ser (re)admitido: propostas de remoção antigas reemitidas;
//   - rede sem blocos novos por mais de STALL_AFTER (e a recuperação).

// blocos após a (re)admissão em que uma remoção é tratada como efeito de propostas antigas
const readmitWindow = 2000

func (b *Bot) incident(title, body string) string {
	body = strings.TrimSpace(body)
	content := fmt.Sprintf("🧾 **Rascunho de issue** (%s), para colar em RBBNet/rbb se couber:\n```\nTítulo: %s\n\n%s\n```", b.cfg.Network, title, body)
	if len(content) > 1900 {
		content = content[:1890] + "\n```"
	}
	webhook := b.cfg.WebhookIncidents
	if webhook == "" {
		webhook = b.cfg.WebhookOrg
	}
	if webhook == "" {
		webhook = b.cfg.WebhookNetwork
	}
	b.lastIncident = content
	b.post(webhook, content)
	return content
}

// Remoção de validator decidida no bloco n, com a lista de quem votou (antes de o placar ser descartado)
func (b *Bot) removalIncident(cand string, voters []string, n uint64) {
	names := b.orgList(voters)
	remaining := len(b.state.Validators) - 1
	when := time.Now().UTC().Format("2006-01-02 15:04 UTC")
	if joined, ok := b.state.Joined[cand]; ok && n >= joined && n-joined <= readmitWindow {
		b.incident(
			fmt.Sprintf("Validator %s removido %d blocos após ser readmitido na %s", b.name(cand), n-joined, b.cfg.Network),
			fmt.Sprintf("O validator %s foi (re)admitido no bloco %d e removido no bloco %d (%s), %d blocos depois.\n"+
				"Votos de remoção: %s.\n\n"+
				"Padrão compatível com propostas de remoção antigas (qbft_proposeValidatorVote ... false) ainda registradas nos nós que o removeram antes: o Besu as reemite assim que o alvo volta ao consenso. "+
				"Ação sugerida: cada casa listada descarta a proposta (qbft_discardValidatorVote) ou atualiza o monitor para a versão que faz esse descarte (RBBNet/monitoracao-validadores, main); depois, nova votação de readmissão.\n"+
				"Validators restantes: %d.", b.name(cand), joined, n, when, n-joined, names, remaining))
		return
	}
	b.incident(
		fmt.Sprintf("Validator %s removido do consenso da %s (bloco %d)", b.name(cand), b.cfg.Network, n),
		fmt.Sprintf("O validator %s saiu do consenso no bloco %d (%s) por votação QBFT.\n"+
			"Votos de remoção: %s.\n"+
			"Se a remoção foi do monitor automático, o nó ficou sem propor blocos por 2000 blocos; verificar com a casa o estado do nó antes de pedir readmissão.\n"+
			"Validators restantes: %d.", b.name(cand), n, when, names, remaining))
}

// Rede parada: a cabeça não avança há mais de cfg.StallAfter
func (b *Bot) checkStall(head uint64) {
	now := time.Now().Unix()
	if head != b.state.LastHead {
		if b.state.Stalled {
			stopped := time.Duration(now-b.state.LastHeadAt) * time.Second
			b.postNetwork(fmt.Sprintf("✅ %s: a rede voltou a produzir blocos (bloco %d) após ~%s parada.", b.cfg.Network, head, humanDur(stopped)))
			b.state.Stalled = false
		}
		b.state.LastHead, b.state.LastHeadAt = head, now
		return
	}
	if b.state.LastHeadAt == 0 {
		b.state.LastHeadAt = now
		return
	}
	stopped := time.Duration(now-b.state.LastHeadAt) * time.Second
	if !b.state.Stalled && stopped >= b.cfg.StallAfter {
		b.state.Stalled = true
		b.postNetwork(fmt.Sprintf("🛑 %s: a rede não produz blocos há ~%s (último bloco %d).", b.cfg.Network, humanDur(stopped), head))
		b.incident(
			fmt.Sprintf("Rede %s sem produzir blocos (último bloco %d)", b.cfg.Network, head),
			fmt.Sprintf("A cabeça da cadeia está parada no bloco %d desde %s (~%s), observado pelo nó %s.\n"+
				"Validators no consenso: %d (%s). O QBFT precisa de mais de 2/3 dos validators conectados entre si para fechar blocos; verificar quais estão fora do ar ou isolados.",
				head, time.Unix(b.state.LastHeadAt, 0).UTC().Format("2006-01-02 15:04 UTC"), humanDur(stopped), b.cfg.RPCURL, len(b.state.Validators), b.orgList(b.state.Validators)))
	}
}
