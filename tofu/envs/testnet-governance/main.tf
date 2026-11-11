locals {
  arn_prefix = "arn:aws:iam::${var.aws_account_id}"
}

module "admin_key" {
  source = "../../modules/aws-governance-key"

  name        = "${var.organization}-rbb-lab-admin"
  description = "Administrador Global da ${upper(var.organization)} na rede lab da RBB (nao exportavel)"

  admin_principal_arns     = [for u in var.admin_iam_users : "${local.arn_prefix}:user/${u}"]
  signer_role_trusted_arns = [for u in var.signer_iam_users : "${local.arn_prefix}:user/${u}"]

  audit_retention_years = var.audit_retention_years
}

# Contas de aplicação (ex.: deployer): mesma custódia da chave de governança, sem trilha própria
# (a trilha do CloudTrail da conta, criada com a chave de governança, registra o uso de todas).
module "application_key" {
  for_each = toset(var.application_keys)
  source   = "../../modules/aws-governance-key"

  name        = "${var.organization}-rbb-lab-${each.key}"
  description = "Conta de aplicacao '${each.key}' da ${upper(var.organization)} na rede lab da RBB (nao exportavel)"

  admin_principal_arns     = [for u in var.admin_iam_users : "${local.arn_prefix}:user/${u}"]
  signer_role_trusted_arns = [for u in var.signer_iam_users : "${local.arn_prefix}:user/${u}"]
  create_trail             = false
}
