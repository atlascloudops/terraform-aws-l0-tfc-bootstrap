# Copyright (c) GEDI, Inc.
# SPDX-License-Identifier: MPL-2.0

# OIDC Provider Details
output "oidc_provider_url" {
  description = "The URL of the HCP Terraform OIDC provider."
  value       = var.create_global_iam_resources ? aws_iam_openid_connect_provider.hcp_terraform[0].url : data.aws_iam_openid_connect_provider.hcp_terraform[0].url
}

output "oidc_provider_arn" {
  description = "The ARN of the HCP Terraform OIDC provider."
  value       = local.oidc_provider_arn
}

output "oidc_thumbprint" {
  description = "The SHA1 fingerprint of the TLS certificate for the OIDC provider."
  value       = data.tls_certificate.provider.certificates[0].sha1_fingerprint
}

# IAM Role Details
output "hcp_terraform_role_arn" {
  description = "The ARN of the IAM role assumed by HCP Terraform via OIDC."
  value       = local.iam_role_arn
}

output "hcp_terraform_role_name" {
  description = "The name of the IAM role assumed by HCP Terraform via OIDC."
  value       = local.iam_role_name
}

# Breakglass Admin Details
output "breakglass_admin_username" {
  description = "The username of the breakglass admin IAM user."
  value       = local.breakglass_user_name
}

output "breakglass_admin_initial_password" {
  description = "The initial password for the breakglass admin IAM user (encrypted if PGP key is provided). Only available when creating resources."
  value       = var.create_global_iam_resources ? try(aws_iam_user_login_profile.breakglass_admin[0].password, null) : null
  sensitive   = true
}

# HCP Terraform Variable Set Details
output "tfe_variable_set_id" {
  description = "The ID of the HCP Terraform variable set containing OIDC configuration. Only available when creating resources."
  value       = var.create_global_iam_resources ? try(tfe_variable_set.this[0].id, null) : null
}

output "tfe_variable_set_name" {
  description = "The name of the HCP Terraform variable set containing OIDC configuration. Only available when creating resources."
  value       = var.create_global_iam_resources ? try(tfe_variable_set.this[0].name, null) : null
}

output "tfe_project_id" {
  description = "The ID of the HCP Terraform project associated with the variable set."
  value       = data.tfe_project.this.id
}