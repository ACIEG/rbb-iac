# Nós RBB em Kubernetes (Rancher Desktop, k3s, ou qualquer cluster): mesma configuração de Besu
# do provedor de VMs (rbb-node-config), aplicada como StatefulSet + PVC + ConfigMaps.
locals {
  labels = { "app.kubernetes.io/part-of" = "rbb", "rbb/organization" = var.organization, "rbb/network" = var.rbb_network }

  # Variáveis do Besu conforme o docker-compose.yml.hbs do start-network para um observer
  # (instanciar_observer.md): sem permissionamento on chain de nós, discovery desligado, static-nodes.
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
    BESU_PERMISSIONS_NODES_CONTRACT_ADDRESS    = var.permissioning_contracts.nodes
    BESU_PERMISSIONS_NODES_CONTRACT_VERSION    = "1"
    BESU_PERMISSIONS_NODES_CONTRACT_ENABLED    = "false"
    BESU_DISCOVERY_ENABLED                     = "false"
  }

  node_env = {
    for k, n in var.nodes : k => merge(
      local.base_env,
      {
        BESU_RPC_HTTP_PORT = tostring(n.rpc_port)
        BESU_METRICS_PORT  = tostring(n.metrics_port)
        BESU_P2P_PORT      = tostring(n.p2p_port)
        BESU_OPTS          = "-Xmx${n.jvm_heap}"
      },
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

resource "kubernetes_config_map_v1" "network" {
  metadata {
    name      = "rbb-network"
    namespace = kubernetes_namespace_v1.rbb.metadata[0].name
    labels    = local.labels
  }
  data = {
    "genesis.json"      = var.genesis_json
    "static-nodes.json" = jsonencode(var.static_nodes)
  }
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
        # imagem oficial roda como usuário besu (uid 1000); o PVC precisa ser gravável por ele
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
            name = kubernetes_config_map_v1.network.metadata[0].name
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
