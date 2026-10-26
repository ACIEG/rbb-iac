# Nós RBB em Kubernetes: mesma configuração de Besu do provedor de VMs (rbb-node-config), por papel:
#   boot           hostNetwork + IP público; discovery ligado; genesis com bootnodes = boots externos
#   validator      hostNetwork + IP público; discovery desligado; static-nodes = validators externos + boots próprios
#   observer-boot  hostNetwork + IP público; sem permissionamento on chain; contas por arquivo (lista vazia); static-nodes = boots próprios
#   writer         interno; discovery desligado; static-nodes = boots próprios
#   observer       interno; sem permissionamento on chain de nós; static-nodes = observer-boots próprios (ou externos)
locals {
  labels      = { "app.kubernetes.io/part-of" = "rbb", "rbb/organization" = var.organization, "rbb/network" = var.rbb_network }
  public_role = { boot = true, validator = true, "observer-boot" = true, writer = false, observer = false }

  # enode de cada nó próprio com chave conhecida: público (hostNetwork) ou interno (Service ClusterIP)
  own_enode = {
    for k, n in var.nodes : k => "enode://${var.node_keys[k].enode_id}@${local.public_role[n.type] ? n.public_ip : kubernetes_service_v1.node[k].spec[0].cluster_ip}:${n.p2p_port}"
    if contains(keys(var.node_keys), k)
  }
  own_boots          = [for k, n in var.nodes : local.own_enode[k] if n.type == "boot" && contains(keys(local.own_enode), k)]
  own_observer_boots = [for k, n in var.nodes : local.own_enode[k] if n.type == "observer-boot" && contains(keys(local.own_enode), k)]

  static_nodes = {
    for k, n in var.nodes : k => (
      n.type == "validator" ? concat(var.external_validators, local.own_boots) :
      n.type == "writer" || n.type == "observer-boot" ? local.own_boots :
      n.type == "observer" ? (length(local.own_observer_boots) > 0 ? local.own_observer_boots : var.external_observer_boots) :
      []
    )
  }

  genesis = jsondecode(var.genesis_json)
  # Boots: discovery.bootnodes = boots das outras organizações (passo 3 do roteiro)
  genesis_boot = jsonencode(merge(local.genesis, {
    config = merge(local.genesis.config, { discovery = { bootnodes = var.external_boots } })
  }))

  base_env = {
    BESU_DATA_PATH                             = "/var/lib/besu"
    BESU_GENESIS_FILE                          = "/etc/rbb/genesis.json"
    BESU_STATIC_NODES_FILE                     = "/etc/rbb/static-nodes.json"
    BESU_MAX_PEERS                             = "50"
    BESU_REMOTE_CONNECTIONS_LIMIT_ENABLED      = "false"
    BESU_MIN_GAS_PRICE                         = "0"
    BESU_TX_POOL                               = "sequenced"
    BESU_RPC_HTTP_ENABLED                      = "true"
    BESU_RPC_HTTP_HOST                         = "0.0.0.0"
    BESU_RPC_HTTP_API                          = "ADMIN,ETH,TXPOOL,NET,QBFT,WEB3,DEBUG,TRACE,PERM"
    BESU_RPC_HTTP_CORS_ORIGINS                 = "*"
    BESU_HOST_ALLOWLIST                        = "*"
    BESU_METRICS_ENABLED                       = "true"
    BESU_METRICS_HOST                          = "0.0.0.0"
    BESU_PERMISSIONS_ACCOUNTS_CONTRACT_ENABLED = "true"
    BESU_PERMISSIONS_ACCOUNTS_CONTRACT_ADDRESS = var.permissioning_contracts.accounts
    BESU_PERMISSIONS_NODES_CONTRACT_ENABLED    = "true"
    BESU_PERMISSIONS_NODES_CONTRACT_ADDRESS    = var.permissioning_contracts.nodes
    BESU_PERMISSIONS_NODES_CONTRACT_VERSION    = "1"
  }
  role_env = {
    boot      = { BESU_DISCOVERY_ENABLED = "true" }
    validator = { BESU_DISCOVERY_ENABLED = "false" }
    writer    = { BESU_DISCOVERY_ENABLED = "false" }
    # instanciar_observer-boot.md: sem permissionamento on chain; contas por arquivo (lista vazia)
    "observer-boot" = {
      BESU_DISCOVERY_ENABLED                        = "true"
      BESU_PERMISSIONS_ACCOUNTS_CONTRACT_ENABLED    = "false"
      BESU_PERMISSIONS_NODES_CONTRACT_ENABLED       = "false"
      BESU_PERMISSIONS_ACCOUNTS_CONFIG_FILE_ENABLED = "true"
      BESU_PERMISSIONS_ACCOUNTS_CONFIG_FILE         = "/etc/rbb/permissioned-accounts.toml"
    }
    # instanciar_observer.md: observer interno sem permissionamento on chain de nós
    observer = { BESU_DISCOVERY_ENABLED = "false", BESU_PERMISSIONS_NODES_CONTRACT_ENABLED = "false" }
  }

  node_env = {
    for k, n in var.nodes : k => merge(
      local.base_env,
      local.role_env[n.type],
      {
        BESU_RPC_HTTP_PORT = tostring(n.rpc_port)
        BESU_METRICS_PORT  = tostring(n.metrics_port)
        BESU_P2P_PORT      = tostring(n.p2p_port)
        BESU_OPTS          = "-Xmx${n.jvm_heap}"
      },
      local.public_role[n.type] ? { BESU_P2P_HOST = n.public_ip } : {},
      n.archive ? { BESU_DATA_STORAGE_FORMAT = "FOREST", BESU_SYNC_MODE = "FULL" } : {},
      n.extra_env,
    )
  }
}

resource "kubernetes_namespace_v1" "rbb" {
  metadata {
    name   = var.namespace
    labels = local.labels
  }
}

# Chave de cada nó (de node_keys) como Secret, montada em /var/lib/besu/key
resource "kubernetes_secret_v1" "key" {
  for_each = var.node_keys
  metadata {
    name      = "${each.key}-key"
    namespace = kubernetes_namespace_v1.rbb.metadata[0].name
    labels    = merge(local.labels, { "rbb/node" = each.key })
  }
  data = { key = var.node_private_keys[each.key] }
}

# Arquivos de rede por nó: genesis (com bootnodes no boot), static-nodes e contas do observer-boot
resource "kubernetes_config_map_v1" "node" {
  for_each = var.nodes
  metadata {
    name      = "${each.key}-network"
    namespace = kubernetes_namespace_v1.rbb.metadata[0].name
    labels    = merge(local.labels, { "rbb/node" = each.key })
  }
  data = merge(
    {
      "genesis.json"      = each.value.type == "boot" ? local.genesis_boot : var.genesis_json
      "static-nodes.json" = jsonencode(local.static_nodes[each.key])
    },
    each.value.type == "observer-boot" ? { "permissioned-accounts.toml" = "accounts-allowlist=[]\n" } : {},
  )
}

resource "kubernetes_service_v1" "node" {
  for_each = var.nodes
  metadata {
    name      = each.key
    namespace = kubernetes_namespace_v1.rbb.metadata[0].name
    labels    = merge(local.labels, { "rbb/node" = each.key, "rbb/type" = each.value.type })
  }
  spec {
    selector = { "rbb/node" = each.key }
    type     = each.value.rpc_node_port == null ? "ClusterIP" : "NodePort"
    port {
      name        = "rpc"
      port        = each.value.rpc_port
      target_port = each.value.rpc_port
      node_port   = each.value.rpc_node_port
    }
    port {
      name        = "metrics"
      port        = each.value.metrics_port
      target_port = each.value.metrics_port
    }
    port {
      name        = "p2p"
      port        = each.value.p2p_port
      target_port = each.value.p2p_port
    }
  }
}

resource "kubernetes_stateful_set_v1" "node" {
  for_each = var.nodes
  metadata {
    name      = each.key
    namespace = kubernetes_namespace_v1.rbb.metadata[0].name
    labels    = merge(local.labels, { "rbb/node" = each.key, "rbb/type" = each.value.type })
  }
  spec {
    service_name = kubernetes_service_v1.node[each.key].metadata[0].name
    replicas     = 1
    selector {
      match_labels = { "rbb/node" = each.key }
    }
    template {
      metadata {
        labels = merge(local.labels, { "rbb/node" = each.key, "rbb/type" = each.value.type })
      }
      spec {
        # Papéis alcançados pela rede: rede do host num nó dedicado com IP público fixo (P2P TCP/UDP no IP real)
        host_network  = local.public_role[each.value.type]
        dns_policy    = local.public_role[each.value.type] ? "ClusterFirstWithHostNet" : "ClusterFirst"
        node_selector = each.value.host != null ? { "kubernetes.io/hostname" = each.value.host } : {}
        security_context {
          run_as_user  = 1000
          run_as_group = 1000
          fs_group     = 1000
        }
        container {
          name  = "besu"
          image = var.besu_image
          args  = ["--Xdns-enabled=true", "--Xdns-update-enabled=true"]
          dynamic "env" {
            for_each = local.node_env[each.key]
            content {
              name  = env.key
              value = env.value
            }
          }
          port {
            name           = "rpc"
            container_port = each.value.rpc_port
          }
          port {
            name           = "metrics"
            container_port = each.value.metrics_port
          }
          port {
            name           = "p2p"
            container_port = each.value.p2p_port
          }
          resources {
            limits   = { memory = each.value.container_memory, cpu = each.value.container_cpus }
            requests = { memory = "1Gi", cpu = "500m" }
          }
          volume_mount {
            name       = "data"
            mount_path = "/var/lib/besu"
          }
          volume_mount {
            name       = "network"
            mount_path = "/etc/rbb"
            read_only  = true
          }
          dynamic "volume_mount" {
            for_each = contains(keys(var.node_keys), each.key) ? [1] : []
            content {
              name       = "key"
              mount_path = "/var/lib/besu/key"
              sub_path   = "key"
              read_only  = true
            }
          }
          readiness_probe {
            http_get {
              path = "/liveness"
              port = each.value.rpc_port
            }
            initial_delay_seconds = 30
            period_seconds        = 15
          }
        }
        volume {
          name = "network"
          config_map {
            name = kubernetes_config_map_v1.node[each.key].metadata[0].name
          }
        }
        dynamic "volume" {
          for_each = contains(keys(var.node_keys), each.key) ? [1] : []
          content {
            name = "key"
            secret {
              secret_name  = kubernetes_secret_v1.key[each.key].metadata[0].name
              default_mode = "0400"
            }
          }
        }
      }
    }
    volume_claim_template {
      metadata {
        name = "data"
      }
      spec {
        access_modes       = ["ReadWriteOnce"]
        storage_class_name = each.value.storage_class
        resources {
          requests = { storage = each.value.data_size }
        }
      }
    }
  }
}
