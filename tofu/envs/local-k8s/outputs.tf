output "nodes" {
  value = module.rbb.nodes
}

output "static_nodes" {
  description = "Enodes usados pelos observers (observer-boots públicos da rede)."
  value       = coalesce(var.static_nodes, local.observer_boots)
}
