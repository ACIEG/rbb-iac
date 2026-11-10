#!/usr/bin/env bash
# Abre um túnel SSH até a porta RPC de um nó (padrão: writer01) e deixa o JSON-RPC em
# http://127.0.0.1:<porta-local>. Serve para implantar contratos e usar Hardhat/Foundry/ethers
# a partir da estação, sem expor o RPC na internet (passo 2.1 do roteiro: RPC só na VPC).
#
# Uso: ./scripts/rbb-rpc-tunnel.sh <testnet|mainnet> [nó] [porta-local]
#   Fica em primeiro plano até Ctrl-C. Exemplo de uso com Hardhat: url http://127.0.0.1:8545,
#   chainId 648629 (lab) ou 12120014 (piloto), gasPrice 0.
# shellcheck disable=SC1091
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
require_env "${1:-}"
env="$1"; node="${2:-writer01}"; lport="${3:-8545}"
host="$(node_host "${env}" "${node}")"
[[ -n "${host}" && "${host}" != "null" ]] || { echo "nó ${node} não encontrado em ${env}" >&2; exit 1; }
rport="$(nodes_json "${env}" | jq -r --arg n "${node}" '.[$n].rpc_port // 8545')"
priv="$(nodes_json "${env}" | jq -r --arg n "${node}" '.[$n].private_ip')"
echo "túnel: http://127.0.0.1:${lport} -> ${node} (${priv}:${rport}) em ${env}. Ctrl-C para fechar."
# shellcheck disable=SC2046
exec ssh "${SSH_OPTS[@]}" $(node_jump_opts "${env}" "${node}") -N -L "127.0.0.1:${lport}:127.0.0.1:${rport}" "${SSH_USER}@${host}"
