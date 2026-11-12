locals {
  prefix = "${var.organization}-rbb-${var.rbb_network}"

  node_keys = sort(keys(var.nodes))

  # IP privado fixo por nó, derivado do tipo e do sequencial (boot01 = .11, validator02 = .22,
  # writer01 = .31, observer-boot01 = .41, observer01 = .51, prometheus01 = .61). Não depende de
  # quais outros nós existem: adicionar ou remover um nó nunca altera o IP dos demais.
  type_ip_base = { boot = 10, validator = 20, writer = 30, "observer-boot" = 40, observer = 50, prometheus = 60, app = 70 }
  private_ips = {
    for k, n in var.nodes : k => cidrhost(var.subnet_cidr, coalesce(n.private_ip_offset, local.type_ip_base[n.type] + tonumber(regex("[0-9]{2}$", k))))
  }

  public_nodes = { for k, n in var.nodes : k => n if n.public_ip }
  besu_nodes   = { for k, n in var.nodes : k => n if !contains(["prometheus", "app"], n.type) }
  volume_nodes = { for k, n in var.nodes : k => n if coalesce(n.data_volume_size, contains(["prometheus", "app"], n.type) ? 0 : var.default_data_volume_size) > 0 }

  protect_data_volumes = coalesce(var.protect_data_volumes, var.rbb_network == "piloto")

  needs_nat = var.nat_gateway == "true" || (var.nat_gateway == "auto" && anytrue([for n in var.nodes : !n.public_ip]))

  ssh_key_name = var.ssh_public_key != null ? mgc_ssh_keys.this[0].name : var.existing_ssh_key_name

  prometheus_targets = [
    for k, n in local.besu_nodes : {
      name = k
      ip   = local.private_ips[k]
      port = n.metrics_port
    }
  ]
  # VMs de aplicação (tipo app): node_exporter na porta 9100, coletado pelo job "app"
  app_targets = [
    for k, n in var.nodes : {
      name = k
      ip   = local.private_ips[k]
      port = 9100
    } if n.type == "app"
  ]
  prometheus_private_cidrs = [for k, n in var.nodes : "${local.private_ips[k]}/32" if n.type == "prometheus"]
  # Nó de salto (bastion): primeiro nó com IP público em ordem alfabética (mesmo critério de bastion_ip)
  bastion_node       = [for k in sort(keys(var.nodes)) : k if var.nodes[k].public_ip]
  bastion_private_ip = length(local.bastion_node) > 0 ? local.private_ips[local.bastion_node[0]] : null
}

# ---------------------------------------------------------------------------
# Configuração agnóstica de cada nó (cloud-init + regras de firewall)
# ---------------------------------------------------------------------------
module "node_config" {
  source   = "../rbb-node-config"
  for_each = var.nodes

  organization      = var.organization
  organization_name = var.organization_name
  rbb_network       = var.rbb_network
  node = {
    name         = each.key
    type         = each.value.type
    p2p_port     = each.value.p2p_port
    rpc_port     = each.value.rpc_port
    metrics_port = each.value.metrics_port
    p2p_public   = each.value.p2p_public
    rpc_public   = each.value.rpc_public
    archive      = each.value.archive
    extra_env    = each.value.extra_env
    service_user = each.value.service_user
    rpc_from_vpc = each.value.rpc_from_vpc
    rpc_proxy    = each.value.rpc_proxy
  }

  private_ip = local.private_ips[each.key]
  public_ip  = each.value.public_ip ? mgc_network_public_ips.this[each.key].public_ip : null
  vpc_cidr   = var.vpc_cidr

  ssh_authorized_keys = var.ssh_authorized_keys
  admin_ssh_cidrs     = var.admin_ssh_cidrs
  participant_cidrs   = var.participant_cidrs
  peer_cidrs          = var.peer_cidrs
  rpc_cidrs           = var.rpc_cidrs
  hostname_public     = var.dns_domain != null && each.value.public_ip ? "rbb-${each.key}.${var.dns_domain}" : null

  genesis_json          = var.genesis_json
  compose_template      = var.compose_template
  start_network_version = var.start_network_version
  besu_image            = var.besu_image
  container_cpus        = coalesce(each.value.container_cpus, var.container_cpus)
  container_memory      = coalesce(each.value.container_memory, var.container_memory)
  jvm_heap              = each.value.jvm_heap
  data_volume           = contains(keys(local.volume_nodes), each.key)

  prometheus_targets            = each.value.type == "prometheus" ? local.prometheus_targets : []
  prometheus_federation_targets = each.value.type == "prometheus" ? var.prometheus_federation_targets : []
  prometheus_app_targets        = each.value.type == "prometheus" ? local.app_targets : []

  # VM de aplicação: SSH só a partir do nó de salto; métricas só para o Prometheus da organização
  ssh_cidrs_override = each.value.type == "app" && local.bastion_private_ip != null ? ["${local.bastion_private_ip}/32"] : null
  # Métricas (Besu, exportador, node_exporter) só para o Prometheus da organização, em todos os nós
  metrics_from_cidrs = length(local.prometheus_private_cidrs) > 0 ? local.prometheus_private_cidrs : null
}

# ---------------------------------------------------------------------------
# Chave SSH
# ---------------------------------------------------------------------------
resource "mgc_ssh_keys" "this" {
  count = var.ssh_public_key != null ? 1 : 0
  name  = "${local.prefix}-admin"
  key   = var.ssh_public_key
}
