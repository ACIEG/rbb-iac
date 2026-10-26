variable "kubeconfig" {
  description = "Caminho do kubeconfig."
  type        = string
  default     = "~/.kube/config"
}

variable "kube_context" {
  description = "Contexto do kubeconfig (ex.: rancher-desktop). Nulo = contexto atual."
  type        = string
  default     = null
}

variable "organization" {
  description = "Sigla da organização (rótulos)."
  type        = string
}

variable "rbb_network" {
  description = "lab ou piloto. Define de qual pasta do participantes vêm genesis e nodes.json (network/)."
  type        = string
  default     = "lab"
}

variable "namespace" {
  type    = string
  default = "rbb"
}

variable "nodes" {
  description = "Observers a criar (ver módulo k8s-rbb-stack)."
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
    rpc_node_port    = optional(number)
    extra_env        = optional(map(string), {})
  }))
  default = { observer01 = { rpc_node_port = 30545 } }
}

variable "static_nodes" {
  description = "Enodes para os observers. Nulo = observer-boots públicos (deployed/active) de network/nodes.json."
  type        = list(string)
  default     = null
}
