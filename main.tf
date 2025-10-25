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

# Data source to reference existing OIDC provider when not creating
data "aws_iam_openid_connect_provider" "hcp_terraform" {
  count    = var.create_global_iam_resources ? 0 : 1
  provider = aws.member_account
  arn      = "arn:aws:iam::${var.member_account_id}:oidc-provider/app.terraform.io"
}

resource "aws_iam_openid_connect_provider" "hcp_terraform" {
  count    = var.create_global_iam_resources ? 1 : 0
  provider = aws.member_account
  url      = local.hcp_terraform_url

  client_id_list = [
    local.hcp_audience,
  ]

  thumbprint_list = [
    data.tls_certificate.provider.certificates[0].sha1_fingerprint,
  ]
}

# Local to reference either created or existing OIDC provider
locals {
  oidc_provider_arn = var.create_global_iam_resources ? aws_iam_openid_connect_provider.hcp_terraform[0].arn : data.aws_iam_openid_connect_provider.hcp_terraform[0].arn
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

# Data source to reference existing IAM role when not creating
data "aws_iam_role" "this" {
  count    = var.create_global_iam_resources ? 0 : 1
  provider = aws.member_account
  name     = local.oidc_role_name
}

# IAM role in the member account that can be assumed by HCP Terraform
resource "aws_iam_role" "this" {
  count              = var.create_global_iam_resources ? 1 : 0
  provider           = aws.member_account
  name               = local.oidc_role_name
  assume_role_policy = data.aws_iam_policy_document.hcp_oidc_assume_role_policy.json
}

# Local to reference either created or existing IAM role
locals {
  iam_role_name = var.create_global_iam_resources ? aws_iam_role.this[0].name : data.aws_iam_role.this[0].name
  iam_role_arn  = var.create_global_iam_resources ? aws_iam_role.this[0].arn : data.aws_iam_role.this[0].arn
}

# Allow the tfc-oidc-role to assume the Route53 delegation role in platform account
resource "aws_iam_role_policy" "allow_crossaccount_route53" {
  count    = var.create_global_iam_resources ? 1 : 0
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
  count      = var.create_global_iam_resources ? 1 : 0
  provider   = aws.member_account
  role       = local.iam_role_name
  policy_arn = "arn:aws:iam::aws:policy/AdministratorAccess"
}

# Data source to reference existing IAM user when not creating
data "aws_iam_user" "breakglass_admin" {
  count     = var.create_global_iam_resources ? 0 : 1
  provider  = aws.member_account
  user_name = local.breakglass_username
}

# Create IAM user for breakglass admin access
resource "aws_iam_user" "breakglass_admin" {
  count    = var.create_global_iam_resources ? 1 : 0
  provider = aws.member_account
  name     = local.breakglass_username
  path     = "/system/"
}

# Create login profile for console access
resource "aws_iam_user_login_profile" "breakglass_admin" {
  count                       = var.create_global_iam_resources ? 1 : 0
  provider                    = aws.member_account
  user                        = var.create_global_iam_resources ? aws_iam_user.breakglass_admin[0].name : data.aws_iam_user.breakglass_admin[0].user_name
  password_reset_required     = true
  password_length             = 24
  #pgp_key                     = var.pgp_key # Base64-encoded PGP public key for secure password delivery
}

# Attach administrator policy to user
resource "aws_iam_user_policy_attachment" "admin_policy" {
  count      = var.create_global_iam_resources ? 1 : 0
  provider   = aws.member_account
  user       = var.create_global_iam_resources ? aws_iam_user.breakglass_admin[0].name : data.aws_iam_user.breakglass_admin[0].user_name
  policy_arn = "arn:aws:iam::aws:policy/AdministratorAccess"
}

# Local to reference either created or existing IAM user
locals {
  breakglass_user_name = var.create_global_iam_resources ? aws_iam_user.breakglass_admin[0].name : data.aws_iam_user.breakglass_admin[0].user_name
}

# Create a TFE variable set for the IAM role in the project
# Variable set name must be unique in organization
# Only create once per account (not per region)

resource "tfe_variable_set" "this" {
  count        = var.create_global_iam_resources ? 1 : 0
  name         = "${var.tfc_project_name}-${local.oidc_role_name}"
  description  = "OIDC federation configuration for HCP Terraform"
  organization = var.tfc_organization_name
}

resource "tfe_variable" "tfc_aws_provider_auth" {
  count           = var.create_global_iam_resources ? 1 : 0
  key             = "TFC_AWS_PROVIDER_AUTH"
  value           = "true"
  category        = "env"
  variable_set_id = tfe_variable_set.this[0].id
}

resource "tfe_variable" "tfc_aws_oidc_role_arn" {
  count           = var.create_global_iam_resources ? 1 : 0
  sensitive       = true
  key             = "TFC_AWS_RUN_ROLE_ARN"
  value           = local.iam_role_arn
  category        = "env"
  variable_set_id = tfe_variable_set.this[0].id
}

data "tfe_project" "this" {
  name         = var.tfc_project_name
  organization = var.tfc_organization_name
}

resource "tfe_project_variable_set" "this" {
  count           = var.create_global_iam_resources ? 1 : 0
  project_id      = data.tfe_project.this.id
  variable_set_id = tfe_variable_set.this[0].id
}
