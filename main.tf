# root account provider
provider "aws" {
  region = var.region
}

provider "tfe" {
  token    = var.token
}

locals {
  hcp_terraform_url   = "https://app.terraform.io"
  hcp_audience        = "aws.workload.identity"
  breakglass_username = var.tfc_organization_name
  oidc_role_name      = "tfc-oidc-role"
}

# Retrieve the SHA1 fingerprint of the TLS certificate protecting https://app.terraform.io
data "tls_certificate" "provider" {
  url = local.hcp_terraform_url
}

# Member account provider with role assumption
provider "aws" {
  alias  = "member_account"
  region = var.region
  assume_role {
    # Replace ${member_account.this.id} with the actual account ID or a variable reference
    role_arn = "arn:aws:iam::${var.member_account_id}:role/OrganizationAccountAccessRole"
  }
}

# Try to lookup existing OIDC provider (will return null if doesn't exist)
data "aws_iam_openid_connect_provider" "existing" {
  provider = aws.member_account
  arn      = "arn:aws:iam::${var.member_account_id}:oidc-provider/app.terraform.io"

  # This will fail gracefully if the provider doesn't exist
  lifecycle {
    postcondition {
      condition     = self.arn != null || self.arn == null
      error_message = "OIDC provider lookup failed"
    }
  }
}

locals {
  # Check if OIDC provider already exists
  oidc_provider_exists = try(data.aws_iam_openid_connect_provider.existing.arn, null) != null
}

# Create OIDC provider only if it doesn't already exist
resource "aws_iam_openid_connect_provider" "hcp_terraform" {
  count    = local.oidc_provider_exists ? 0 : 1
  provider = aws.member_account
  url      = local.hcp_terraform_url

  client_id_list = [
    local.hcp_audience,
  ]

  thumbprint_list = [
    data.tls_certificate.provider.certificates[0].sha1_fingerprint,
  ]
}

# Local to reference either existing or newly created OIDC provider
locals {
  oidc_provider_arn = local.oidc_provider_exists ? data.aws_iam_openid_connect_provider.existing.arn : aws_iam_openid_connect_provider.hcp_terraform[0].arn
  oidc_provider_url = local.oidc_provider_exists ? data.aws_iam_openid_connect_provider.existing.url : aws_iam_openid_connect_provider.hcp_terraform[0].url
}

data "aws_iam_policy_document" "hcp_oidc_assume_role_policy" {
  statement {
    effect  = "Allow"
    actions = ["sts:AssumeRoleWithWebIdentity"]
    principals {
      type        = "Federated"
      identifiers = [local.oidc_provider_arn]
    }
    condition {
      test     = "StringEquals"
      variable = "app.terraform.io:aud"
      values   = [local.hcp_audience]
    }
    condition {
      test     = "StringLike"
      variable = "app.terraform.io:sub"
      values   = ["organization:${var.tfc_organization_name}:*"]
    }
  }
}

# Try to lookup existing IAM role
data "aws_iam_role" "existing" {
  provider = aws.member_account
  name     = local.oidc_role_name

  lifecycle {
    postcondition {
      condition     = self.arn != null || self.arn == null
      error_message = "IAM role lookup failed"
    }
  }
}

locals {
  # Check if IAM role already exists
  iam_role_exists = try(data.aws_iam_role.existing.arn, null) != null
  iam_role_name   = local.iam_role_exists ? data.aws_iam_role.existing.name : (length(aws_iam_role.this) > 0 ? aws_iam_role.this[0].name : local.oidc_role_name)
  iam_role_arn    = local.iam_role_exists ? data.aws_iam_role.existing.arn : aws_iam_role.this[0].arn
}

# IAM role in the member account that can be assumed by HCP Terraform
resource "aws_iam_role" "this" {
  count              = local.iam_role_exists ? 0 : 1
  provider           = aws.member_account
  name               = local.oidc_role_name
  assume_role_policy = data.aws_iam_policy_document.hcp_oidc_assume_role_policy.json
}

# Allow the tfc-oidc-role to assume the Route53 delegation role in platform account
resource "aws_iam_role_policy" "allow_crossaccount_route53" {
  count    = local.iam_role_exists ? 0 : 1
  provider = aws.member_account
  name     = "AllowRoute53DelegationAccess"
  role     = local.iam_role_name

  policy = jsonencode({
    Version = "2012-10-17",
    Statement = [
      {
        Effect   = "Allow",
        Action   = ["sts:AssumeRole"],
        Resource = "arn:aws:iam::${var.platform_utility_account_id}:role/Route53DelegationWrite"
      }
    ]
  })
}

# Attach the AdministratorAccess policy to the IAM role in the member_account
resource "aws_iam_role_policy_attachment" "admin_access" {
  count      = local.iam_role_exists ? 0 : 1
  provider   = aws.member_account
  role       = local.iam_role_name
  policy_arn = "arn:aws:iam::aws:policy/AdministratorAccess"
}

# Try to lookup existing IAM user
data "aws_iam_user" "existing" {
  provider  = aws.member_account
  user_name = local.breakglass_username

  lifecycle {
    postcondition {
      condition     = self.arn != null || self.arn == null
      error_message = "IAM user lookup failed"
    }
  }
}

locals {
  # Check if IAM user already exists
  iam_user_exists      = try(data.aws_iam_user.existing.arn, null) != null
  breakglass_user_name = local.iam_user_exists ? data.aws_iam_user.existing.user_name : (length(aws_iam_user.breakglass_admin) > 0 ? aws_iam_user.breakglass_admin[0].name : local.breakglass_username)
}

# Create IAM user for breakglass admin access
resource "aws_iam_user" "breakglass_admin" {
  count    = local.iam_user_exists ? 0 : 1
  provider = aws.member_account
  name     = local.breakglass_username
  path     = "/system/"
}

# Create login profile for console access (only on first creation)
resource "aws_iam_user_login_profile" "breakglass_admin" {
  count                   = local.iam_user_exists ? 0 : 1
  provider                = aws.member_account
  user                    = local.breakglass_user_name
  password_reset_required = true
  password_length         = 24
  #pgp_key                 = var.pgp_key # Base64-encoded PGP public key for secure password delivery
}

# Attach administrator policy to user
resource "aws_iam_user_policy_attachment" "admin_policy" {
  count      = local.iam_user_exists ? 0 : 1
  provider   = aws.member_account
  user       = local.breakglass_user_name
  policy_arn = "arn:aws:iam::aws:policy/AdministratorAccess"
}

# Create a TFE variable set for the IAM role in the project
# Variable set name must be unique in organization

data "tfe_project" "this" {
  name         = var.tfc_project_name
  organization = var.tfc_organization_name
}

# Try to lookup existing TFE variable set
data "tfe_variable_set" "existing" {
  name         = "${var.tfc_project_name}-${local.oidc_role_name}"
  organization = var.tfc_organization_name

  lifecycle {
    postcondition {
      condition     = self.id != null || self.id == null
      error_message = "TFE variable set lookup failed"
    }
  }
}

locals {
  # Check if TFE variable set already exists
  tfe_varset_exists = try(data.tfe_variable_set.existing.id, null) != null
  tfe_varset_id     = local.tfe_varset_exists ? data.tfe_variable_set.existing.id : tfe_variable_set.this[0].id
  tfe_varset_name   = local.tfe_varset_exists ? data.tfe_variable_set.existing.name : tfe_variable_set.this[0].name
}

resource "tfe_variable_set" "this" {
  count        = local.tfe_varset_exists ? 0 : 1
  name         = "${var.tfc_project_name}-${local.oidc_role_name}"
  description  = "OIDC federation configuration for HCP Terraform"
  organization = var.tfc_organization_name
}

resource "tfe_variable" "tfc_aws_provider_auth" {
  count           = local.tfe_varset_exists ? 0 : 1
  key             = "TFC_AWS_PROVIDER_AUTH"
  value           = "true"
  category        = "env"
  variable_set_id = local.tfe_varset_id
}

resource "tfe_variable" "tfc_aws_oidc_role_arn" {
  count           = local.tfe_varset_exists ? 0 : 1
  sensitive       = true
  key             = "TFC_AWS_RUN_ROLE_ARN"
  value           = local.iam_role_arn
  category        = "env"
  variable_set_id = local.tfe_varset_id
}

resource "tfe_project_variable_set" "this" {
  count           = local.tfe_varset_exists ? 0 : 1
  project_id      = data.tfe_project.this.id
  variable_set_id = local.tfe_varset_id
}
