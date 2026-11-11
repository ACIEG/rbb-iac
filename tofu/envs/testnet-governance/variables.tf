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
