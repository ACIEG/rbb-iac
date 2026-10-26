output "nodes" {
  value = module.rbb.nodes
}

output "static_nodes" {
  description = "static-nodes aplicados a cada nó."
  value       = module.rbb.static_nodes
}
