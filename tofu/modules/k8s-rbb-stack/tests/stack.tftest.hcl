mock_provider "kubernetes" {}

variables {
  organization        = "ORG1"
  rbb_network         = "lab"
  genesis_json        = "{\"config\":{\"chainId\":648629}}"
  external_boots      = ["enode://bb@203.0.113.2:30303"]
  external_validators = ["enode://cc@203.0.113.3:30303"]
  node_keys = {
    boot01      = { enode_id = "aa01", address = "0x0a" }
    validator01 = { enode_id = "aa02", address = "0x0b" }
  }
  node_private_keys = { boot01 = "0x01", validator01 = "0x02" }
  nodes = {
    boot01          = { type = "boot", host = "node-a", public_ip = "203.0.113.10" }
    validator01     = { type = "validator", host = "node-b", public_ip = "203.0.113.11" }
    writer01        = { type = "writer" }
    observer-boot01 = { type = "observer-boot", host = "node-c", public_ip = "203.0.113.12" }
    observer01      = { type = "observer", archive = true, rpc_node_port = 30545 }
  }
}

run "topologia_por_papel" {
  command = plan
  assert {
    condition     = tolist(local.static_nodes["validator01"]) == tolist(["enode://cc@203.0.113.3:30303", "enode://aa01@203.0.113.10:30303"]) && tolist(local.static_nodes["writer01"]) == tolist(["enode://aa01@203.0.113.10:30303"])
    error_message = "validator: validators externos + boot próprio; writer: boot próprio."
  }
  assert {
    condition     = jsondecode(kubernetes_config_map_v1.node["boot01"].data["genesis.json"]).config.discovery.bootnodes == ["enode://bb@203.0.113.2:30303"] && !can(jsondecode(kubernetes_config_map_v1.node["writer01"].data["genesis.json"]).config.discovery)
    error_message = "só o genesis do boot recebe bootnodes."
  }
  assert {
    condition     = local.node_env["boot01"]["BESU_P2P_HOST"] == "203.0.113.10" && local.node_env["boot01"]["BESU_DISCOVERY_ENABLED"] == "true" && local.node_env["validator01"]["BESU_DISCOVERY_ENABLED"] == "false"
    error_message = "boot anuncia o IP público e usa discovery; validator não."
  }
  assert {
    condition     = local.node_env["observer-boot01"]["BESU_PERMISSIONS_NODES_CONTRACT_ENABLED"] == "false" && local.node_env["observer-boot01"]["BESU_PERMISSIONS_ACCOUNTS_CONFIG_FILE_ENABLED"] == "true" && kubernetes_config_map_v1.node["observer-boot01"].data["permissioned-accounts.toml"] == "accounts-allowlist=[]\n"
    error_message = "observer-boot: permissionamento local de contas com lista vazia."
  }
  assert {
    condition     = local.node_env["observer01"]["BESU_DATA_STORAGE_FORMAT"] == "FOREST" && local.node_env["observer01"]["BESU_PERMISSIONS_NODES_CONTRACT_ENABLED"] == "false" && local.node_env["writer01"]["BESU_PERMISSIONS_NODES_CONTRACT_ENABLED"] == "true"
    error_message = "observer archive (Forest) sem permissionamento de nós; writer com permissionamento on chain."
  }
  assert {
    condition     = kubernetes_stateful_set_v1.node["boot01"].spec[0].template[0].spec[0].host_network == true && kubernetes_stateful_set_v1.node["writer01"].spec[0].template[0].spec[0].host_network == false
    error_message = "hostNetwork só nos papéis alcançados pela rede."
  }
}

run "papel_publico_exige_host_e_ip" {
  command = plan
  variables {
    nodes = { validator01 = { type = "validator" } }
  }
  expect_failures = [var.nodes]
}
