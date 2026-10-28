# Ambiente: testnet (rede RBB "lab")

variable "mgc_api_key" {
  description = "API key da Magalu Cloud. Prefira exportar TF_VAR_mgc_api_key."
  type        = string
  sensitive   = true
}

variable "mgc_region" {
  description = "Região da Magalu Cloud (br-se1 ou br-ne1)."
  type        = string
  default     = "br-se1"
}

variable "availability_zone" {
  type    = string
  default = "br-se1-a"
}

variable "organization" {
  description = "Nome curto da organização (minúsculas). Ex.: exemplo"
  type        = string
}

variable "organization_name" {
  description = "Nome do partícipe como consta em participantes/lab/nodes.json (ex.: BNDES, PUC-Rio). Padrão: organization em maiúsculas."
  type        = string
  default     = null
}

variable "ssh_public_key" {
  description = "Chave pública SSH dos administradores."
  type        = string
  default     = null
}

variable "ssh_authorized_keys" {
  description = "Chaves públicas SSH adicionais (ex.: chave institucional da organização, guardada fora do operador)."
  type        = list(string)
  default     = []
}

variable "existing_ssh_key_name" {
  type    = string
  default = null
}

variable "admin_ssh_cidrs" {
  description = "CIDRs com acesso SSH. Não use 0.0.0.0/0."
  type        = list(string)
}

variable "participant_cidrs" {
  description = "CIDRs dos demais partícipes (P2P e Prometheus). Padrão: qualquer origem."
  type        = list(string)
  default     = ["0.0.0.0/0"]
}

variable "participants_file" {
  description = "Arquivo com IPs por papel das outras organizações (gerado por rbb-sync-participantes.sh). Se existir e firewall_from_participants = true, restringe P2P e 8443 a esses IPs (passo 9 do roteiro)."
  type        = string
  default     = "network/participants.json"
}

variable "firewall_from_participants" {
  description = "Restringir P2P dos nós núcleo e 8443 do Prometheus aos IPs de network/participants.json. false = usa participant_cidrs."
  type        = bool
  default     = true
}

variable "dns_domain" {
  description = "Domínio DNS público da organização (opcional), para hostNames no nodes.json. Ex.: exemplo.org.br"
  type        = string
  default     = null
}

variable "rpc_cidrs" {
  description = "CIDRs adicionais com acesso à porta RPC (aplicações da organização)."
  type        = list(string)
  default     = []
}

variable "vpc_cidr" {
  type    = string
  default = "10.120.0.0/16"
}

variable "subnet_cidr" {
  type    = string
  default = "10.120.1.0/24"
}

variable "default_machine_type" {
  description = "Tipo de máquina padrão (BV<vcpu>-<ram>-<disco>)."
  type        = string
  default     = "BV2-4-20"
}

variable "default_data_volume_size" {
  description = "Volume de dados (GB) por nó Besu. Referência RBB: 400 GB."
  type        = number
  default     = 400
}

variable "data_volume_type" {
  type    = string
  default = "cloud_nvme1k"
}

variable "container_cpus" {
  type    = number
  default = 2
}

variable "container_memory" {
  type    = string
  default = "3G"
}

variable "nodes" {
  description = "Nós da organização nesta rede. Padrão: topologia de partícipe associado."
  type = map(object({
    type              = string
    machine_type      = optional(string)
    data_volume_size  = optional(number)
    public_ip         = optional(bool, true)
    p2p_public        = optional(bool)
    rpc_public        = optional(bool, false)
    p2p_port          = optional(number, 30303)
    rpc_port          = optional(number, 8545)
    metrics_port      = optional(number, 9545)
    archive           = optional(bool, false)
    extra_env         = optional(map(string), {})
    container_cpus    = optional(number)
    container_memory  = optional(string)
    jvm_heap          = optional(string)
    private_ip_offset = optional(number)
    # Liga/desliga o plugin de permissionamento neste nó (nulo = permissioning_plugin.enabled)
    permissioning_plugin = optional(bool)
  }))
  default = {
    boot01          = { type = "boot" }
    validator01     = { type = "validator" }
    writer01        = { type = "writer" }
    observer-boot01 = { type = "observer-boot" }
    prometheus01    = { type = "prometheus", data_volume_size = 0 }
  }
}

variable "genesis_file" {
  description = "Caminho do genesis.json da rede lab (RBBNet/participantes/lab/genesis.json). Nulo = não iniciar o Besu."
  type        = string
  default     = "network/genesis.json"
}

variable "compose_template_file" {
  description = "Caminho de um docker-compose.yml.hbs específico da rede (participantes/lab/docker-compose.yml.hbs). Ignorado se o arquivo não existir."
  type        = string
  default     = "network/docker-compose.yml.hbs"
}

variable "federation_file" {
  description = "Arquivo JSON com os Prometheus das outras organizações (gerado por scripts/rbb-sync-participantes.sh). Somado a prometheus_federation_targets."
  type        = string
  default     = "network/federation.json"
}

variable "start_network_version" {
  type    = string
  default = "v1.2.0"
}

variable "besu_image" {
  description = "Besu <= 25.5.0 (exigência da RBB)."
  type        = string
  default     = "hyperledger/besu:25.5.0"
}

variable "protect_data_volumes" {
  description = "prevent_destroy nos volumes de dados. Nulo = padrão do módulo (true em piloto, false em lab)."
  type        = bool
  default     = null
}

variable "nat_gateway" {
  description = "NAT gateway para saída à internet. 'true' (padrão) é necessário porque o bootstrap roda antes de o IP público ser anexado à VM."
  type        = string
  default     = "true"
}

variable "prometheus_federation_targets" {
  type = list(object({
    organization = string
    target       = string
  }))
  default = []
}

variable "validator_monitor" {
  description = <<-EOT
    Monitoração automática de validators (RBBNet/monitoracao-validadores), instalada nos nós validator quando enabled = true.
    A cada interval_seconds consulta qbft_getSignerMetrics dos últimos block_interval blocos no próprio validator e vota
    (qbft_proposeValidatorVote) pela exclusão de quem não propôs nenhum bloco, como a rede espera de cada partícipe.
    repo é owner/repo no GitHub e ref uma branch, tag ou commit (o código é baixado como tarball, sem git).
  EOT
  type = object({
    enabled          = optional(bool, false)
    repo             = optional(string, "RBBNet/monitoracao-validadores")
    ref              = optional(string, "main")
    block_interval   = optional(number, 2000)
    interval_seconds = optional(number, 300)
    image            = optional(string, "node:24-alpine")
  })
  default = {}
}

variable "permissioning_plugin" {
  description = <<-EOT
    Plugin de permissionamento on-chain da RBB (RBBNet/besu-permissioning-plugin), que substitui o permissionamento
    nativo removido do Besu a partir da 25.6. Versões fixadas: imagem do Besu compatível, URL do jar do release e seu SHA-256.
    enabled liga o plugin nos nós (pode ser sobreposto por nó em nodes[*].permissioning_plugin). A instalação troca a
    imagem do Besu e monta o jar via docker-compose.override.yml, mantendo chave e banco (rbb-node plugin install).
    Só para nós já sincronizados: um nó novo com o plugin não consegue sincronizar do gênesis (defeito conhecido do rc.1).
  EOT
  type = object({
    enabled    = optional(bool, false)
    besu_image = optional(string, "hyperledger/besu:25.12.0@sha256:4ef9e934bb321d916ff245981fd65100dc41446b26b2bed47a2b7d09139a3cbe")
    jar_url    = optional(string, "https://github.com/RBBNet/besu-permissioning-plugin/releases/download/v1.0.0-rc.1/besu-plugin-permissioning.jar")
    jar_sha256 = optional(string, "5d7eebac3de229fd5940fe919a9535c8aeab2be5108dc1bd2231a07ba33955bd")
  })
  default = {}
}
