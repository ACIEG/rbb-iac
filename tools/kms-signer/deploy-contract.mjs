// Implanta um contrato compilado (artefato com abi e bytecode, como os do Hardhat ou do solc)
// assinando com uma chave no AWS KMS, sem chave privada em arquivo.
//
// Uso: node deploy-contract.mjs <alias-kms> <artefato.json> [argumentos do construtor...]
// Ambiente: JSON_RPC_URL (padrão http://127.0.0.1:8545, via scripts/rbb-rpc-tunnel.sh), AWS_REGION,
//   credenciais AWS, RBB_KMS_ROLE_ARN (opcional, papel de assinatura da chave).
// A conta da chave precisa estar cadastrada na RBB como DEPLOYER_ROLE (permission-account.mjs).
import { readFileSync } from "node:fs";
import { ContractFactory, JsonRpcProvider } from "ethers";
import { KmsSigner } from "./kms-signer.mjs";

const [alias, artifactPath, ...ctorArgs] = process.argv.slice(2);
if (!alias || !artifactPath) {
  console.error("uso: node deploy-contract.mjs <alias-kms> <artefato.json> [argumentos do construtor...]");
  process.exit(2);
}
const artifact = JSON.parse(readFileSync(artifactPath, "utf8"));
const bytecode = artifact.bytecode?.object ?? artifact.bytecode ?? artifact.evm?.bytecode?.object;
if (!artifact.abi || !bytecode) { console.error("artefato sem abi/bytecode"); process.exit(2); }

const provider = new JsonRpcProvider(process.env.JSON_RPC_URL || "http://127.0.0.1:8545");
const signer = new KmsSigner(alias).connect(provider);
const from = await signer.getAddress();
const net = await provider.getNetwork();
console.log(`rede ${net.chainId} | conta ${from} (KMS ${alias}) | ${artifact.contractName ?? artifactPath}`);

const factory = new ContractFactory(artifact.abi, bytecode, signer);
const contract = await factory.deploy(...ctorArgs, { gasPrice: 0 });
const tx = contract.deploymentTransaction();
console.log(`tx ${tx.hash}`);
const rc = await tx.wait();
console.log(`bloco ${rc.blockNumber}, status ${rc.status === 1 ? "ok" : "falhou"}`);
console.log(`contrato: ${await contract.getAddress()}`);
