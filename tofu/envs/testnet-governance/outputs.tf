output "key_arn" {
  value = module.admin_key.key_arn
}

output "alias" {
  value = module.admin_key.alias
}

output "signer_role_arn" {
  value = module.admin_key.signer_role_arn
}

output "audit_bucket" {
  value = module.admin_key.audit_bucket
}

output "next_step" {
  value = "Endereço Ethereum: (cd tools/kms-signer && npm ci && npm run address -- ${module.admin_key.alias})"
}

output "application_keys" {
  description = "Contas de aplicação: alias do KMS e papel de assinatura de cada uma."
  value       = { for k, m in module.application_key : k => { alias = m.alias, signer_role_arn = m.signer_role_arn } }
}

output "application_service_users" {
  description = "Contas de serviço criadas; gere a chave de acesso com: aws iam create-access-key --user-name <nome>"
  value       = [for u in aws_iam_user.application_service : u.name]
}

output "issuer_keys" {
  description = "Chaves de emissor: alias do KMS por id."
  value       = { for k, m in module.issuer_key : k => m.alias }
}

output "issuer_queue_role_arn" {
  description = "Papel único da fila de emissão (kms:Sign/GetPublicKey só nas chaves de emissor)."
  value       = local.issuer_queue_on ? aws_iam_role.issuer_queue[0].arn : null
}
