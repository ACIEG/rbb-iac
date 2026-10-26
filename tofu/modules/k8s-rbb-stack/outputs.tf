output "namespace" {
  value = kubernetes_namespace_v1.rbb.metadata[0].name
}

output "nodes" {
  description = "Nós criados: serviço interno do RPC e, se houver, NodePort."
  value = {
    for k, n in var.nodes : k => {
      type         = n.type
      rpc_url      = "http://${k}.${var.namespace}.svc:${n.rpc_port}"
      node_port    = n.rpc_node_port
      port_forward = "kubectl -n ${var.namespace} port-forward svc/${k} ${n.rpc_port}:${n.rpc_port}"
    }
  }
}
