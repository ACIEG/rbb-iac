# rbb-kms-signer

Assina transações Ethereum da RBB com uma chave **secp256k1 no AWS KMS**: a chave privada nunca existe fora do KMS, cada assinatura fica no CloudTrail e a permissão de assinar é revogável.

```bash
cd tools/kms-signer && npm install
export AWS_REGION=sa-east-1            # credenciais AWS pelo ambiente ou AWS_PROFILE
export RBB_KMS_ROLE_ARN=arn:aws:iam::<conta>:role/<org>-rbb-lab-admin-signer   # opcional: assume o papel de assinatura
node cli.mjs address alias/exemplo-rbb-lab-admin      # endereço a informar à governança da RBB
node cli.mjs sign-test alias/exemplo-rbb-lab-admin    # assina e verifica (gera um evento kms:Sign no CloudTrail)
```

`KmsSigner` (em `kms-signer.mjs`) é um `Signer` do ethers v6 e pode ser usado no lugar de `new Wallet(PRIVATE_KEY)` em scripts de permissionamento:

```js
import { JsonRpcProvider } from "ethers";
import { KmsSigner } from "./kms-signer.mjs";
const signer = new KmsSigner("alias/exemplo-rbb-lab-admin").connect(new JsonRpcProvider(process.env.JSON_RPC_URL));
```

## Permissionar uma conta da organização

`permission-account.mjs` cadastra (ou atualiza) uma conta no `AccountRulesV2` assinando com a chave do KMS, sem chave privada em arquivo. Padrão: `DEPLOYER_ROLE`, para contas que implantam contratos.

```bash
JSON_RPC_URL=http://127.0.0.1:8545 node permission-account.mjs alias/exemplo-rbb-lab-admin ../../tofu/envs/testnet/network/contracts.json 0x<endereço> [DEPLOYER_ROLE|USER_ROLE] [dataHash]
```
## Implantar um contrato com a chave no KMS

`deploy-contract.mjs` implanta um artefato compilado (abi + bytecode, formato do Hardhat ou do solc) assinando com uma chave do KMS, que deve estar cadastrada como `DEPLOYER_ROLE`. `examples/Oracle.sol` (e o artefato `Oracle.json`, solc 0.8.28, evmVersion london) é um oráculo mínimo para exercitar o ciclo.

```bash
JSON_RPC_URL=http://127.0.0.1:8545 node deploy-contract.mjs alias/exemplo-rbb-lab-deployer examples/Oracle.json
```

Para operar o contrato depois, use `KmsSigner` como signer do ethers (`new Contract(endereco, abi, signer)`). Compile com `evmVersion` compatível com a rede (a RBB lab está em `london`; `shanghai` gera `PUSH0`, que o Besu da rede pode não aceitar).
