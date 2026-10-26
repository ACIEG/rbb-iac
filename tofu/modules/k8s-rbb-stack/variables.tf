variable "namespace" {
  description = "Namespace Kubernetes onde os nós são criados."
  type        = string
  default     = "rbb"
}

variable "organization" {
  description = "Sigla da organização (rótulos e nomes de host)."
  type        = string
}

variable "rbb_network" {
  description = "Rede RBB: lab ou piloto."
  type        = string
  validation {
    condition     = contains(["lab", "piloto"], var.rbb_network)
    error_message = "rbb_network deve ser lab ou piloto."
  }
}

variable "besu_image" {
  description = "Imagem do Besu, fixada na versão homologada pela RBB."
  type        = string
  default     = "hyperledger/besu:25.5.0"
}

variable "genesis_json" {
  description = "Conteúdo do genesis.json da rede (participantes/<rede>/genesis.json)."
  type        = string
}

variable "static_nodes" {
  description = "Enodes aos quais os observers se conectam (observer-boots públicos da rede, participantes/<rede>/nodes.json)."
  type        = list(string)
  default     = []
}

variable "nodes" {
  description = <<-EOT
    Nós a criar, indexados pelo nome (padrão da RBB: observer01, observer02...). Neste provedor só o tipo
    "observer" (nó de leitura, sem permissionamento on chain de nós, discovery desligado): boot, validator,
    writer e observer-boot exigem IP público fixo e permissionamento, fora do alcance de um cluster local.
    archive = true usa Forest + sync FULL (estado histórico completo, para explorador/auditoria).
  EOT
  type = map(object({
    type             = optional(string, "observer")
    archive          = optional(bool, false)
    rpc_port         = optional(number, 8545)
    metrics_port     = optional(number, 9545)
    p2p_port         = optional(number, 30303)
    data_size        = optional(string, "100Gi")
    storage_class    = optional(string)
    container_memory = optional(string, "6Gi")
    container_cpus   = optional(string, "2")
    jvm_heap         = optional(string, "3g")
    rpc_node_port    = optional(number) # expõe o RPC em NodePort (30000-32767); nulo = só dentro do cluster
    extra_env        = optional(map(string), {})
  }))
  validation {
    condition     = alltrue([for n in var.nodes : n.type == "observer"])
    error_message = "Neste provedor só nós do tipo observer são suportados."
  }
}

variable "permissioning_contracts" {
  description = "Endereços dos contratos de permissionamento (como no docker-compose da rede)."
  type = object({
    accounts = optional(string, "0x0000000000000000000000000000000000008888")
    nodes    = optional(string, "0x0000000000000000000000000000000000009999")
  })
  default = {}
}
