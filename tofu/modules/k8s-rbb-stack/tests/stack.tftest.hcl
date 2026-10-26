mock_provider "kubernetes" {}

variables {
  organization = "ORG1"
  rbb_network  = "lab"
  genesis_json = "{\"config\":{}}"
  static_nodes = ["enode://aa@203.0.113.1:30303"]
  nodes = {
    observer01 = { rpc_node_port = 30545 }
    observer02 = { archive = true, jvm_heap = "4g", extra_env = { BESU_LOGGING = "DEBUG" } }
  }
}

run "observer_env" {
  command = plan
  assert {
    condition     = local.node_env["observer01"]["BESU_PERMISSIONS_NODES_CONTRACT_ENABLED"] == "false" && local.node_env["observer01"]["BESU_DISCOVERY_ENABLED"] == "false"
    error_message = "observer: permissionamento de nós desligado e discovery desligado."
  }
  assert {
    condition     = local.node_env["observer02"]["BESU_DATA_STORAGE_FORMAT"] == "FOREST" && local.node_env["observer02"]["BESU_SYNC_MODE"] == "FULL" && local.node_env["observer02"]["BESU_OPTS"] == "-Xmx4g" && local.node_env["observer02"]["BESU_LOGGING"] == "DEBUG"
    error_message = "archive: Forest + FULL, heap e extra_env aplicados."
  }
  assert {
    condition     = kubernetes_service_v1.node["observer01"].spec[0].type == "NodePort" && kubernetes_service_v1.node["observer02"].spec[0].type == "ClusterIP"
    error_message = "rpc_node_port define NodePort; sem ele, ClusterIP."
  }
}

run "so_observer" {
  command = plan
  variables {
    nodes = { boot01 = { type = "boot" } }
  }
  expect_failures = [var.nodes]
}
