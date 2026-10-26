output "namespace" {
  value = kubernetes_namespace_v1.rbb.metadata[0].name
}

output "nodes" {
  description = "Nós criados: papel, enode anunciado (quando a chave é conhecida), acesso ao RPC."
  value = {
    for k, n in var.nodes : k => {
      type         = n.type
      public_ip    = n.public_ip
      enode        = try(local.own_enode[k], null)
      address      = try(var.node_keys[k].address, null)
      rpc_url      = "http://${k}.${var.namespace}.svc:${n.rpc_port}"
      node_port    = n.rpc_node_port
      port_forward = "kubectl -n ${var.namespace} port-forward svc/${k} ${n.rpc_port}:${n.rpc_port}"
    }
  }
}

output "static_nodes" {
  description = "static-nodes aplicados a cada nó (verificação da topologia do passo 3)."
  value       = local.static_nodes
}
