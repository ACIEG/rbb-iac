#!/usr/bin/env bash
# Funções comuns dos scripts locais da infra RBB.
set -euo pipefail

INFRA_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# Credenciais (Magalu, AWS do backend S3) de .env (raiz do repositório), como faz o Makefile
if [[ -f "${INFRA_DIR}/.env" ]]; then
  set -a
  # shellcheck disable=SC1091
  source "${INFRA_DIR}/.env"
  set +a
fi
SSH_USER="${RBB_SSH_USER:-ubuntu}"
SSH_OPTS=(-o StrictHostKeyChecking=accept-new -o ConnectTimeout=15 -o BatchMode=yes)

env_dir() { echo "${INFRA_DIR}/tofu/envs/$1"; }

require_env() {
  local env="${1:-}"
  [[ "${env}" == "testnet" || "${env}" == "mainnet" ]] || { echo "uso: $0 <testnet|mainnet> ..." >&2; exit 1; }
  [[ -d "$(env_dir "${env}")" ]] || { echo "ambiente ${env} não encontrado" >&2; exit 1; }
  # Os arquivos locais (terraform.tfvars, backend.tf, .env) ficam fora do git: num clone sem eles o tofu
  # usa um estado local vazio e nada funciona. Aponta o problema em vez de falhar mais adiante.
  if [[ ! -f "$(env_dir "${env}")/terraform.tfvars" ]]; then
    echo "arquivos locais ausentes em $(env_dir "${env}") (terraform.tfvars, backend.tf) e/ou ${INFRA_DIR}/.env." >&2
    echo "Este clone (${INFRA_DIR}) não tem os segredos: use o clone configurado ou restaure-os (README, seção 'Arquivos locais e dotswap')." >&2
    exit 1
  fi
}

_NODES_CACHE=""
nodes_json() {
  # Cacheia 'tofu output' (lento) durante a execução do script
  if [[ -z "${_NODES_CACHE}" ]]; then
    _NODES_CACHE="$(cd "$(env_dir "$1")" && tofu output -json nodes)"
    [[ "${_NODES_CACHE}" != "{}" && -n "${_NODES_CACHE}" ]] || { echo "sem nós no estado de $1 (execute tofu apply)" >&2; exit 1; }
  fi
  printf '%s' "${_NODES_CACHE}"
}

node_host() {
  # IP de acesso SSH (público; se ausente, privado — requer bastion/VPN)
  nodes_json "$1" | jq -r --arg n "$2" '.[$n] | (.public_ip // .private_ip)'
}

_BASTION_CACHE=""; _BASTION_SET=false
bastion_ip() {
  # Cacheia: 'tofu output' consulta o backend remoto e era chamado a cada ssh para nós privados
  if ! ${_BASTION_SET}; then
    _BASTION_CACHE="$( (cd "$(env_dir "$1")" && tofu output -raw bastion_ip 2>/dev/null) || true)"; _BASTION_SET=true
  fi
  printf '%s' "${_BASTION_CACHE}"
}

# Opções de salto quando o nó não tem IP público
node_jump_opts() {
  local env="$1" node="$2"
  local pub; pub="$(nodes_json "${env}" | jq -r --arg n "${node}" '.[$n].public_ip // empty')"
  if [[ -z "${pub}" ]]; then
    local b; b="$(bastion_ip "${env}")"
    [[ -n "${b}" ]] && printf -- '-J %s@%s' "${SSH_USER}" "${b}"
  fi
}

node_ssh() {
  local env="$1" node="$2"; shift 2
  local host; host="$(node_host "${env}" "${node}")"
  # shellcheck disable=SC2046
  ssh "${SSH_OPTS[@]}" $(node_jump_opts "${env}" "${node}") "${SSH_USER}@${host}" "$@"
}

nodes_of_type() { nodes_json "$1" | jq -r --arg t "$2" 'to_entries[] | select(.value.type == $t) | .key'; }

_PEERS_MAP_CACHE=""
peers_map_json() {
  # Mapa IP -> organização/nó/tipo para o exportador rbb-peers (/etc/rbb/peers-map.json):
  # nós das outras organizações (network/nodes.json, IPs públicos) + os nossos (IPs privado e público, own=true).
  # Atenção ao bash 3.2 do macOS: não envolver o jq em "$(...)" com aspas duplas (expande $vars do programa jq).
  local env="$1" netdir orgname
  netdir="$(env_dir "${env}")/network"
  orgname=$(cd "$(env_dir "${env}")" && tofu output -raw organization_name 2>/dev/null || echo "ORG")
  if [[ -z "${_PEERS_MAP_CACHE}" ]]; then
    _PEERS_MAP_CACHE=$(
      {
        if [[ -f "${netdir}/nodes.json" ]]; then
          jq -c --arg own_org "${orgname}" '[.[] | select(.organization != $own_org) | .organization as $theirs | .nodes[] | select(.ipAddresses != null) | .ipAddresses[] as $addr | {ip: $addr, organization: $theirs, node: .name, type: .nodeType, port: .port, id: (.id // null), own: false}]' "${netdir}/nodes.json"
        fi
        nodes_json "${env}" | jq -c --arg own_org "${orgname}" '[to_entries[] | .key as $name | .value as $val | ([$val.private_ip, $val.public_ip] | map(select(. != null and . != ""))[]) as $addr | {ip: $addr, organization: $own_org, node: $name, type: $val.type, port: (($val.p2p_address // "") | split(":") | .[1] // "30303" | tonumber), own: true}]'
      } | jq -s 'add | unique_by([.ip, .port])'
    )
  fi
  printf '%s' "${_PEERS_MAP_CACHE}"
}
