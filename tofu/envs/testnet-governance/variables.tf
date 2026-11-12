# Cofre de chaves de governança da organização na rede lab (testnet) da RBB.
# Estado separado da infra dos nós (Magalu): conta e provedor diferentes.

variable "aws_account_id" {
  description = "ID da conta AWS da organização titular (12 dígitos). Protege contra aplicar na conta errada."
  type        = string
  validation {
    condition     = can(regex("^[0-9]{12}$", var.aws_account_id))
    error_message = "Informe os 12 dígitos, sem hífens."
  }
}

variable "aws_region" {
  type    = string
  default = "sa-east-1"
}

variable "organization" {
  description = "Nome curto da organização (minúsculas). Ex.: exemplo"
  type        = string
}

variable "admin_iam_users" {
  description = "Usuários IAM da organização que administram a chave e a trilha (não assinam)."
  type        = list(string)
}

variable "signer_iam_users" {
  description = "Usuários IAM autorizados a assumir o papel de assinatura (operação técnica)."
  type        = list(string)
  default     = []
}

variable "audit_retention_years" {
  type    = number
  default = 5
}

variable "application_keys" {
  description = <<-EOT
    Contas de aplicação da organização (implantação e operação de contratos), também no KMS: uma chave por nome,
    ex.: ["deployer"] cria <org>-rbb-lab-deployer, com papel de assinatura próprio para os mesmos signer_iam_users.
    Cadastre o endereço de cada uma como DEPLOYER_ROLE ou USER_ROLE com tools/kms-signer/permission-account.mjs.
  EOT
  type        = list(string)
  default     = []
}

variable "application_service_users" {
  description = <<-EOT
    Contas de serviço (usuários IAM sem console) para operar as contas de aplicação: só podem assumir o papel de
    assinatura das chaves em application_keys. Ex.: ["tracetus-rbb-operator"]. As chaves de acesso são criadas
    fora do estado (aws iam create-access-key) e entregues ao operador.
  EOT
  type        = list(string)
  default     = []
}

variable "issuer_keys" {
  description = <<-EOT
    Chaves de emissor (uma por emissor, no KMS): cada id cria alias/<org>-rbb-lab-issuer-<id>. Nenhuma tem papel
    próprio: todas são assinadas pelo papel único da fila (<org>-rbb-lab-issuer-queue), que só pode kms:Sign e
    kms:GetPublicKey nelas e tem negação explícita nas demais chaves (governança e aplicação). Emissor novo = id novo
    aqui e um apply; cadastre o endereço de cada chave na RBB (permission-account.mjs) como USER_ROLE ou DEPLOYER_ROLE.
  EOT
  type        = list(string)
  default     = []
}

variable "issuer_queue_service_user" {
  description = "Conta de serviço IAM (sem console) da fila de emissão: só pode assumir o papel da fila. Nulo = não cria."
  type        = string
  default     = null
}

variable "issuer_queue_source_ips" {
  description = "IPs (CIDR) de onde a fila assume o papel; vazio = sem restrição. Ex.: IP de saída do NAT da VPC."
  type        = list(string)
  default     = []
}
