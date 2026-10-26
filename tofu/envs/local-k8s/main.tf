locals {
  netdir     = "${path.module}/network"
  genesis    = file("${local.netdir}/genesis.json")
  nodes_json = try(jsondecode(file("${local.netdir}/nodes.json")), [])
  read_list  = { for f in ["boots", "validators"] : f => try([for l in split("\n", file("${local.netdir}/${f}.txt")) : l if startswith(l, "enode://")], []) }
  # observer-boots públicos da rede (deployed/active), para observers sem observer-boot próprio
  observer_boots = flatten([
    for org in local.nodes_json : [
      for n in org.nodes : "enode://${replace(n.pubKey, "0x", "")}@${n.ipAddresses[0]}:${n.port}"
      if n.nodeType == "observer-boot" && try(n.deploymentStatus, "deployed") == "deployed" && try(n.operationalStatus, "active") == "active" && length(try(n.ipAddresses, [])) > 0
    ]
  ])
  # chaves só para os papéis que a rede precisa conhecer de antemão (enode publicado no nodes.json)
  keyed_nodes = { for k, n in var.nodes : k => n if contains(["boot", "validator", "observer-boot", "writer"], n.type) }
}

# Chave de nó estável (tools/rbb-keygen): gravada em keys/<nó>.key, fora do git. Requer Go.
data "external" "key" {
  for_each = local.keyed_nodes
  program  = ["go", "run", "${path.module}/../../../tools/rbb-keygen"]
  query    = { name = each.key, dir = "${path.module}/keys" }
}

module "rbb" {
  source = "../../modules/k8s-rbb-stack"

  namespace               = var.namespace
  organization            = var.organization
  rbb_network             = var.rbb_network
  genesis_json            = local.genesis
  external_boots          = local.read_list["boots"]
  external_validators     = local.read_list["validators"]
  external_observer_boots = coalesce(var.static_nodes, local.observer_boots)
  node_keys               = { for k, d in data.external.key : k => { enode_id = d.result.enode_id, address = d.result.address } }
  node_private_keys       = { for k, d in data.external.key : k => d.result.private }
  nodes                   = var.nodes
}
