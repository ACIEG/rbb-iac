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

# ---------------------------------------------------------------------------
# Emissores: uma chave por emissor, um papel único para a fila, uma conta de serviço própria
# ---------------------------------------------------------------------------
module "issuer_key" {
  for_each = toset(var.issuer_keys)
  source   = "../../modules/aws-governance-key"

  name                     = "${var.organization}-rbb-lab-issuer-${each.key}"
  description              = "Emissor '${each.key}' da ${upper(var.organization)} na rede lab da RBB (nao exportavel; assinado pelo papel da fila)"
  admin_principal_arns     = [for u in var.admin_iam_users : "${local.arn_prefix}:user/${u}"]
  signer_role_trusted_arns = []                                 # sem papel por chave
  signer_principal_arns    = [aws_iam_role.issuer_queue[0].arn] # só o papel da fila assina (política da chave nega os demais)
  create_trail             = false
}

locals {
  issuer_key_arns   = [for k, m in module.issuer_key : m.key_arn]
  other_key_arns    = concat([module.admin_key.key_arn], [for k, m in module.application_key : m.key_arn])
  issuer_queue_name = "${var.organization}-rbb-lab-issuer-queue"
  issuer_queue_on   = length(var.issuer_keys) > 0
}

# Papel da fila: só assina com as chaves de emissor desta rede; negação explícita nas demais
data "aws_iam_policy_document" "issuer_queue_trust" {
  count = local.issuer_queue_on ? 1 : 0
  statement {
    actions = ["sts:AssumeRole"]
    principals {
      type        = "AWS"
      identifiers = compact([var.issuer_queue_service_user != null ? aws_iam_user.issuer_queue[0].arn : null])
    }
    dynamic "condition" {
      for_each = length(var.issuer_queue_source_ips) > 0 ? [1] : []
      content {
        test     = "IpAddress"
        variable = "aws:SourceIp"
        values   = var.issuer_queue_source_ips
      }
    }
  }
}

data "aws_iam_policy_document" "issuer_queue" {
  count = local.issuer_queue_on ? 1 : 0
  statement {
    sid       = "SignWithIssuerKeys"
    actions   = ["kms:Sign", "kms:GetPublicKey"]
    resources = local.issuer_key_arns
  }
  statement {
    sid       = "DenyOtherKeys"
    effect    = "Deny"
    actions   = ["kms:*"]
    resources = local.other_key_arns
  }
}

resource "aws_iam_role" "issuer_queue" {
  count                = local.issuer_queue_on ? 1 : 0
  name                 = local.issuer_queue_name
  description          = "Fila de emissao da ${upper(var.organization)} na rede lab da RBB: kms:Sign e kms:GetPublicKey so nas chaves de emissor"
  assume_role_policy   = data.aws_iam_policy_document.issuer_queue_trust[0].json
  max_session_duration = 3600
}

resource "aws_iam_role_policy" "issuer_queue" {
  count  = local.issuer_queue_on ? 1 : 0
  name   = "sign-with-issuer-keys-only"
  role   = aws_iam_role.issuer_queue[0].id
  policy = data.aws_iam_policy_document.issuer_queue[0].json
}

# Conta de serviço da fila: sem console, única permissão é assumir o papel da fila
resource "aws_iam_user" "issuer_queue" {
  count = var.issuer_queue_service_user != null ? 1 : 0
  name  = var.issuer_queue_service_user
  tags  = { "rbb:purpose" = "fila de emissao (assume so o papel da fila)" }
}

data "aws_iam_policy_document" "issuer_queue_user" {
  count = var.issuer_queue_service_user != null && local.issuer_queue_on ? 1 : 0
  statement {
    actions   = ["sts:AssumeRole"]
    resources = [aws_iam_role.issuer_queue[0].arn]
  }
}

resource "aws_iam_user_policy" "issuer_queue" {
  count  = var.issuer_queue_service_user != null && local.issuer_queue_on ? 1 : 0
  name   = "assume-issuer-queue-role"
  user   = aws_iam_user.issuer_queue[0].name
  policy = data.aws_iam_policy_document.issuer_queue_user[0].json
}
