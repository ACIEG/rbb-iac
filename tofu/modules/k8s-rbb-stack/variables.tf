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

variable "external_boots" {
  description = "Enodes dos boots das OUTRAS organizações (network/boots.txt): bootnodes do genesis dos nossos boots."
  type        = list(string)
  default     = []
}

variable "external_validators" {
  description = "Enodes dos validators das OUTRAS organizações (network/validators.txt): static-nodes dos nossos validators."
  type        = list(string)
  default     = []
}

variable "external_observer_boots" {
  description = "Enodes dos observer-boots públicos da rede: static-nodes de observers quando não há observer-boot próprio (ex.: cluster local só com observer)."
  type        = list(string)
  default     = []
}

variable "node_keys" {
  description = <<-EOT
    Identidade pública dos nós (geradas com tools/rbb-keygen): enode_id (128 hex) e address. Nós sem entrada
    aqui (ex.: observer) geram a própria chave no primeiro início e não entram nos static-nodes dos outros.
  EOT
  type = map(object({
    enode_id = string
    address  = string
  }))
  default = {}
}

variable "node_private_keys" {
  description = "Chave privada (0x…32 bytes) por nó, para os mesmos nomes de node_keys. Mantida fora do git."
  type        = map(string)
  default     = {}
  sensitive   = true
}

variable "nodes" {
  description = <<-EOT
    Nós, indexados pelo nome no padrão da RBB (boot01, validator01, writer01, observer-boot01, observer01).
    Papéis que a rede alcança (boot, validator, observer-boot) rodam na rede do host (hostNetwork) de um nó
    dedicado do cluster com IP público fixo: informe host (nome do nó Kubernetes) e public_ip; o firewall
    desse nó (passo 9 do roteiro) é gerenciado fora deste módulo. writer e observer ficam internos (ClusterIP).
  EOT
  type = map(object({
    type             = string
    host             = optional(string) # nó do cluster (kubernetes.io/hostname) para papéis com hostNetwork
    public_ip        = optional(string) # IP público anunciado (BESU_P2P_HOST) para boot/validator/observer-boot
    archive          = optional(bool, false)
    rpc_port         = optional(number, 8545)
    metrics_port     = optional(number, 9545)
    p2p_port         = optional(number, 30303)
    data_size        = optional(string, "400Gi")
    storage_class    = optional(string)
    container_memory = optional(string, "6Gi")
    container_cpus   = optional(string, "2")
    jvm_heap         = optional(string, "3g")
    rpc_node_port    = optional(number) # expõe o RPC em NodePort; nulo = só dentro do cluster
    extra_env        = optional(map(string), {})
  }))
  validation {
    condition     = alltrue([for n in var.nodes : contains(["boot", "validator", "writer", "observer-boot", "observer"], n.type)])
    error_message = "type deve ser boot, validator, writer, observer-boot ou observer."
  }
  validation {
    condition     = alltrue([for k, n in var.nodes : !contains(["boot", "validator", "observer-boot"], n.type) || (n.host != null && n.public_ip != null)])
    error_message = "boot, validator e observer-boot precisam de host (nó do cluster) e public_ip."
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
