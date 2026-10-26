# rbb-votes-bot

Acompanha as votações da RBB e avisa num canal do Discord. Só leitura, só fatos.

- **Votações QBFT** (entrada/saída de validators do consenso): lidas nos cabeçalhos dos blocos. Avisa quando um validator passa a votar, muda ou retira o voto, com o placar (`N de M necessários`), e quando o conjunto de validators muda.
- **Propostas de governança gen02** (contrato `Governance`): nova proposta (com prazo estimado), voto de cada organização (com placar), aprovação/rejeição/execução, e **aviso de prazo** listando quem ainda não votou.
- Dois canais: o da rede (tudo acima, factual) e o da organização (só o que diz respeito a nós: votos no nosso validator, entrada/saída do consenso, proposta pendente do nosso voto).

## Uso

```bash
cd tools/rbb-votes-bot && go build -o rbb-votes-bot .
RPC_URL=http://127.0.0.1:8545 \
GOVERNANCE_ADDRESS=0x8Ed5f47E1CBf30de81ea1fab5f678319F35AF667 \
ORGANIZATION_ADDRESS=0xc1636FcC2627202a9a20aa052884D05343309Eb9 \
NODES_JSON=../../tofu/envs/testnet/network/nodes.json \
ORG_NAME=ACIEG RBB_NETWORK=TESTNET \
DISCORD_WEBHOOK_NETWORK=https://discord.com/api/webhooks/... \
DISCORD_WEBHOOK_ORG=https://discord.com/api/webhooks/... \
./rbb-votes-bot -state ./state.json -poll 30s
```

Sem webhooks, as mensagens vão só para o log (modo de teste). `-once` faz uma varredura e sai. Os endereços dos contratos estão em `participantes/<rede>/contratos.md` (`network/contracts.json` após `rbb-sync-participantes.sh`).

O estado (último bloco lido, votos pendentes conhecidos, propostas) fica em `STATE_FILE`; na primeira execução o bot começa do bloco atual, sem reprocessar o passado. Se ficar parado, retoma pelos últimos 2000 blocos.

## Onde rodar

Precisa de um RPC de um nó da rede. Como a RBB é permissionada e o RPC nunca é público, o lugar natural é o nó `prometheus` da organização (dentro da VPC, alcança o RPC do boot), como mais um serviço do compose do Prometheus:

```yaml
  votes-bot:
    build: ./rbb-votes-bot          # ou image: ghcr.io/<org>/rbb-votes-bot
    restart: unless-stopped
    env_file: ./votes-bot.env       # RPC_URL, GOVERNANCE_ADDRESS, ORGANIZATION_ADDRESS, ORG_NAME, DISCORD_WEBHOOK_*
    volumes:
      - ./network/nodes.json:/etc/rbb/nodes.json:ro
      - votes-bot-state:/var/lib/rbb-votes-bot
    environment:
      NODES_JSON: /etc/rbb/nodes.json
```

Um único bot por rede basta: o serviço é portátil e pode ser hospedado por qualquer organização apontando para um nó próprio.

## Mensagens (exemplos)

```
🗳️ TESTNET: TCU vota ADICIONAR o validator BNDES/validator02 — 3 de 5 necessários. Bloco 22521300.
✅ TESTNET: validator BNDES/validator02 ENTROU no consenso. Agora são 9 validators. Bloco 22521352.
📜 TESTNET: nova proposta de governança 8 — "Permissionamento da XYZ", proposta por BNDES. Vence no bloco 22600000 (~2 dias). Precisa da maioria de 9 organizações votantes.
🗳️ TESTNET: SERPRO APROVOU a proposta 8 (Permissionamento da XYZ) — 2 aprovações / 0 rejeições.
⏳ TESTNET: proposta 8 (Permissionamento da XYZ) vence em ~20 h e está com 4 aprovações / 0 rejeições. Quem ainda não votou: CPQD, RNP, IBICT.
```
