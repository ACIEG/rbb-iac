// Cadastra (ou atualiza) uma conta da organização no AccountRulesV2 da RBB assinando com a chave
// de Administrador Global no AWS KMS. Equivale ao `account-rules-v2.js addLocalAccount` dos
// scripts-permissionamento, sem chave privada em arquivo.
//
// Uso: node permission-account.mjs <alias-kms> <contracts.json> <endereço> [papel] [dataHash]
//   alias-kms      ex.: alias/exemplo-rbb-lab-admin (saída `alias` de envs/<rede>-governance)
//   contracts.json tofu/envs/<rede>/network/contracts.json (rbb-sync-participantes.sh)
//   papel          DEPLOYER_ROLE (padrão), USER_ROLE, LOCAL_ADMIN_ROLE ou GLOBAL_ADMIN_ROLE
// Ambiente: JSON_RPC_URL (padrão http://127.0.0.1:8545, via rbb-rpc-tunnel.sh), AWS_REGION,
//   credenciais AWS, RBB_KMS_ROLE_ARN (opcional, papel de assinatura).
import { readFileSync } from "node:fs";
import { Contract, JsonRpcProvider, ZeroHash } from "ethers";
import { KmsSigner } from "./kms-signer.mjs";

const ROLES = {
  GLOBAL_ADMIN_ROLE: "0xd6e7d8560c69c7c18c2b8f3b45430215d788f128f0c04bc4a3607fe05eb5399f",
  LOCAL_ADMIN_ROLE: "0xb7f8beecafe1ad662cec1153812612581a86b9460f21b876f3ee163141203dcb",
  DEPLOYER_ROLE: "0xfc425f2263d0df187444b70e47283d622c70181c5baebb1306a01edba1ce184c",
  USER_ROLE: "0x14823911f2da1b49f045a0929a60b8c1f2a7fc8c06c7284ca3e8ab4e193a08c8",
};
const ABI = [
  "function addLocalAccount(address account, bytes32 roleId, bytes32 dataHash) external",
  "function updateLocalAccount(address account, bytes32 roleId, bytes32 dataHash) external",
  "function getAccount(address account) view returns (tuple(address account, uint256 orgId, bytes32 roleId, bytes32 dataHash, bool active))",
];

const [alias, contractsPath, account, roleName = "DEPLOYER_ROLE", dataHash = ZeroHash] = process.argv.slice(2);
if (!alias || !contractsPath || !account) {
  console.error("uso: node permission-account.mjs <alias-kms> <contracts.json> <endereço> [papel] [dataHash]");
  process.exit(2);
}
const roleId = ROLES[roleName];
if (!roleId) { console.error(`papel desconhecido: ${roleName} (${Object.keys(ROLES).join(", ")})`); process.exit(2); }
const contracts = JSON.parse(readFileSync(contractsPath, "utf8"));
const rulesAddr = contracts.AccountRulesV2Impl;
if (!rulesAddr) { console.error(`AccountRulesV2Impl ausente em ${contractsPath}`); process.exit(2); }

const provider = new JsonRpcProvider(process.env.JSON_RPC_URL || "http://127.0.0.1:8545");
const signer = new KmsSigner(alias).connect(provider);
const admin = await signer.getAddress();
const rules = new Contract(rulesAddr, ABI, signer);
console.log(`admin (KMS ${alias}): ${admin}`);
console.log(`AccountRulesV2Impl: ${rulesAddr} | conta: ${account} | papel: ${roleName}`);

let existing = null;
try { existing = await rules.getAccount(account); } catch { /* conta inexistente: getAccount reverte */ }
const fn = existing && existing.account?.toLowerCase() === account.toLowerCase() ? "updateLocalAccount" : "addLocalAccount";
const tx = await rules[fn](account, roleId, dataHash, { gasPrice: 0 });
console.log(`${fn}: tx ${tx.hash}`);
const rc = await tx.wait();
console.log(`bloco ${rc.blockNumber}, status ${rc.status === 1 ? "ok" : "falhou"}`);
const after = await rules.getAccount(account);
console.log(`conta ${after.account} org ${after.orgId} papel ${Object.entries(ROLES).find(([, v]) => v === after.roleId)?.[0] ?? after.roleId} ativa ${after.active}`);
