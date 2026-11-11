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

  admin_principal_arns = [for u in var.admin_iam_users : "${local.arn_prefix}:user/${u}"]
  signer_role_trusted_arns = concat(
    [for u in var.signer_iam_users : "${local.arn_prefix}:user/${u}"],
    [for u in aws_iam_user.application_service : u.arn],
  )
  create_trail = false
}

# Contas de serviço dos operadores das contas de aplicação: sem console, sem outras permissões.
resource "aws_iam_user" "application_service" {
  for_each = toset(var.application_service_users)
  name     = each.key
  tags     = { "rbb:purpose" = "operador de contas de aplicação" }
}

data "aws_iam_policy_document" "application_service" {
  count = length(var.application_service_users) > 0 && length(var.application_keys) > 0 ? 1 : 0
  statement {
    sid       = "AssumeApplicationSignerRoles"
    actions   = ["sts:AssumeRole"]
    resources = [for k, m in module.application_key : m.signer_role_arn]
  }
}

resource "aws_iam_user_policy" "application_service" {
  for_each = length(var.application_keys) > 0 ? aws_iam_user.application_service : {}
  name     = "assume-application-signer-roles"
  user     = each.value.name
  policy   = data.aws_iam_policy_document.application_service[0].json
}
