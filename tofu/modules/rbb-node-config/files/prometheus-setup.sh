#!/usr/bin/env bash
# Bootstrap do nó prometheus<NN> da RBB. Chamado por rbb-node-setup.
# Cria a estrutura em ${DATA_MOUNT}/prometheus e sobe Prometheus + NGINX (443 UI, 8443 mTLS /federate).
set -euo pipefail

# shellcheck disable=SC1091
source /etc/rbb/node.env

PROM_HOME="${DATA_MOUNT}/prometheus"
mkdir -p "${PROM_HOME}"/{targets,certs,logs}
for f in prometheus.yml rules.yml nginx.conf docker-compose.yml blackbox.yml; do
  [[ -f "/etc/rbb/prometheus/${f}" ]] && cp -f "/etc/rbb/prometheus/${f}" "${PROM_HOME}/${f}"
done
# Alvos: sempre reescreve os locais; os federados só na primeira vez (depois via 'rbb-node prometheus federation')
cp -f /etc/rbb/prometheus/targets/local.json "${PROM_HOME}/targets/local.json"
[[ -f "${PROM_HOME}/targets/federation.json" ]] || cp /etc/rbb/prometheus/targets/federation.json "${PROM_HOME}/targets/federation.json"

# Certificado autoassinado do servidor (roteiro_prometheus_nginx.md, passo 2). Válido por 2 anos.
if [[ ! -f "${PROM_HOME}/certs/chave-privada.key" ]]; then
  CN="${PUBLIC_IP:-${PRIVATE_IP}}"
  openssl genrsa -out "${PROM_HOME}/certs/chave-privada.key" 4096
  openssl req -new -key "${PROM_HOME}/certs/chave-privada.key" \
    -out "${PROM_HOME}/certs/pedido.csr" \
    -subj "/C=BR/O=${ORGANIZATION_NAME}-RBB/CN=${CN}"
  openssl x509 -req -days 730 -in "${PROM_HOME}/certs/pedido.csr" \
    -signkey "${PROM_HOME}/certs/chave-privada.key" \
    -out "${PROM_HOME}/certs/certificado.pem"
fi
# client.pem: certificados dos demais partícipes (participantes/<rede>/certificados).
# Começa com o próprio certificado para que o NGINX suba; substitua via 'rbb-node prometheus clients'.
[[ -f "${PROM_HOME}/certs/client.pem" ]] || cp "${PROM_HOME}/certs/certificado.pem" "${PROM_HOME}/certs/client.pem"
chmod 644 "${PROM_HOME}/certs/"*

# Usuário da interface web (senha aleatória gravada em ${PROM_HOME}/.htpasswd-initial, legível só por root).
if [[ ! -f "${PROM_HOME}/.htpasswd" ]]; then
  PW="$(openssl rand -base64 18)"
  htpasswd -cbB "${PROM_HOME}/.htpasswd" admin "${PW}"
  (umask 077; printf 'admin:%s\n' "${PW}" > "${PROM_HOME}/.htpasswd-initial")
fi

# Grafana: provisionamento (fonte de dados + painéis versionados) e senha inicial do admin
# (gravada em ${PROM_HOME}/.grafana-admin-initial, legível só por root). URL: https://<ip>/grafana/
mkdir -p "${PROM_HOME}/grafana/provisioning/datasources" "${PROM_HOME}/grafana/provisioning/dashboards"
cp -f /etc/rbb/prometheus/grafana-datasources.yml "${PROM_HOME}/grafana/provisioning/datasources/prometheus.yml"
cp -f /etc/rbb/prometheus/grafana-dashboards.yml "${PROM_HOME}/grafana/provisioning/dashboards/rbb.yml"
cp -f /etc/rbb/prometheus/grafana-dashboard-nos.json "${PROM_HOME}/grafana/provisioning/dashboards/rbb-nos.json"
if [[ ! -f "${PROM_HOME}/grafana/grafana.env" ]]; then
  GPW="$(openssl rand -base64 18)"
  printf 'GF_SECURITY_ADMIN_PASSWORD=%s\nGF_SERVER_ROOT_URL=https://%s/grafana/\n' "${GPW}" "${PUBLIC_IP:-${PRIVATE_IP}}" > "${PROM_HOME}/grafana/grafana.env"
  (umask 077; printf 'admin:%s\n' "${GPW}" > "${PROM_HOME}/.grafana-admin-initial")
fi
chmod 600 "${PROM_HOME}/grafana/grafana.env"

chown -R rbb:rbb "${PROM_HOME}"
chown root:root "${PROM_HOME}/.htpasswd-initial" "${PROM_HOME}/.grafana-admin-initial" 2>/dev/null || true

# Bot de votações (opcional, VOTES_BOT_ENABLED no node.env): clona o código na ref fixada e sobe como serviço próprio
if [[ "${VOTES_BOT_ENABLED:-false}" == "true" ]]; then
  BOT_HOME="${DATA_MOUNT}/votes-bot"
  mkdir -p "${BOT_HOME}"
  if [[ ! -d "${BOT_HOME}/src/.git" ]]; then
    git clone -q --depth 1 -b "${VOTES_BOT_REF}" "${VOTES_BOT_REPO}" "${BOT_HOME}/src"
  else
    (cd "${BOT_HOME}/src" && git fetch -q --depth 1 origin "${VOTES_BOT_REF}" && git checkout -q FETCH_HEAD)
  fi
  (umask 077; cat > "${BOT_HOME}/votes-bot.env" <<BOTENV
RPC_URL=${VOTES_BOT_RPC_URL}
GOVERNANCE_ADDRESS=${VOTES_BOT_GOVERNANCE}
ORGANIZATION_ADDRESS=${VOTES_BOT_ORGANIZATION}
NODES_JSON=/etc/rbb/nodes.json
ORG_NAME=${ORGANIZATION_NAME}
RBB_NETWORK=${VOTES_BOT_NETWORK}
BOT_NAME=RBB votações
DISCORD_WEBHOOK_NETWORK=${VOTES_BOT_WEBHOOK_NET}
DISCORD_WEBHOOK_ORG=${VOTES_BOT_WEBHOOK_ORG}
BOTENV
  )
  [[ -f "${BOT_HOME}/nodes.json" ]] || printf '[]\n' > "${BOT_HOME}/nodes.json"   # atualizado por rbb-link-nodes.sh
  cat > "${BOT_HOME}/docker-compose.yml" <<BOTCOMPOSE
services:
  votes-bot:
    build: ./src/tools/rbb-votes-bot
    restart: unless-stopped
    env_file: ./votes-bot.env
    volumes:
      - ./nodes.json:/etc/rbb/nodes.json:ro
      - votes-bot-state:/var/lib/rbb-votes-bot
    logging:
      driver: json-file
      options:
        max-size: "10m"
        max-file: "3"
volumes:
  votes-bot-state:
BOTCOMPOSE
  chown -R rbb:rbb "${BOT_HOME}"; chmod 600 "${BOT_HOME}/votes-bot.env"
  (cd "${BOT_HOME}" && sudo -u rbb -H docker compose up -d --build >/dev/null 2>&1) && echo "[rbb] bot de votações iniciado em ${BOT_HOME}"
fi

cd "${PROM_HOME}"
sudo -u rbb -H docker compose up -d
# nginx.conf é bind mount: recarrega para aplicar mudanças sem recriar o contêiner
sudo -u rbb -H docker compose exec -T nginx nginx -s reload >/dev/null 2>&1 || true
echo "[rbb] Prometheus + NGINX + Grafana iniciados em ${PROM_HOME}"
