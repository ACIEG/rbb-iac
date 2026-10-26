locals {
  netdir  = "${path.module}/network"
  genesis = file("${local.netdir}/genesis.json")
  # observer-boots públicos da rede, a partir do nodes.json do participantes (rbb-sync-participantes.sh)
  # try(): sem nodes.json a lista fica vazia (tipos consistentes para o condicional)
  nodes_json = try(jsondecode(file("${local.netdir}/nodes.json")), [])
  observer_boots = flatten([
    for org in local.nodes_json : [
      for n in org.nodes : "enode://${replace(n.pubKey, "0x", "")}@${n.ipAddresses[0]}:${n.port}"
      if n.nodeType == "observer-boot" && try(n.deploymentStatus, "deployed") == "deployed" && try(n.operationalStatus, "active") == "active" && length(try(n.ipAddresses, [])) > 0
    ]
  ])
}

module "rbb" {
  source = "../../modules/k8s-rbb-stack"

  namespace    = var.namespace
  organization = var.organization
  rbb_network  = var.rbb_network
  genesis_json = local.genesis
  static_nodes = coalesce(var.static_nodes, local.observer_boots)
  nodes        = var.nodes
}
