Member account onboarding + OIDC federation setup

## Overview

This Terraform module configures HCP Terraform (Terraform Cloud) OIDC federation for AWS member accounts. It creates:
- AWS IAM OIDC provider for HCP Terraform
- IAM role with trust policy for OIDC authentication
- Breakglass IAM user for emergency console access
- HCP Terraform variable set with AWS OIDC configuration

## Multi-Region Idempotency

This module is designed to be idempotent across multiple regional deployments in the same AWS account. Since IAM resources are **global** (not region-specific), the module supports conditional resource creation.

### Usage Pattern

**First Regional Deployment (e.g., us-east-1):**
```hcl
module "tfc_bootstrap" {
  source = "./terraform-aws-l0-tfc-bootstrap"

  create_global_iam_resources = true  # Create IAM resources
  region                      = "us-east-1"
  member_account_id           = "123456789012"
  tfc_organization_name       = "my-org"
  tfc_project_name            = "my-project"
  platform_utility_account_id = "999888777666"
  token                       = var.tfc_token
}
```

**Subsequent Regional Deployments (e.g., us-west-2):**
```hcl
module "tfc_bootstrap" {
  source = "./terraform-aws-l0-tfc-bootstrap"

  create_global_iam_resources = false  # Import existing IAM resources
  region                      = "us-west-2"
  member_account_id           = "123456789012"
  tfc_organization_name       = "my-org"
  tfc_project_name            = "my-project"
  platform_utility_account_id = "999888777666"
  token                       = var.tfc_token
}
```

When `create_global_iam_resources = false`, the module uses data sources to reference existing global IAM resources instead of attempting to create them, preventing resource collision errors.

## Variables

| Name | Description | Type | Default | Required |
|------|-------------|------|---------|----------|
| `create_global_iam_resources` | Create global IAM resources (OIDC provider, IAM role, IAM user). Set to false for secondary regional deployments. | `bool` | `true` | no |
| `region` | AWS region where resources will be created | `string` | `"us-east-1"` | no |
| `member_account_id` | AWS member account ID where OIDC provider and role will be created | `string` | - | yes |
| `tfc_organization_name` | HCP Terraform organization name | `string` | - | yes |
| `tfc_project_name` | HCP Terraform project name | `string` | - | yes |
| `platform_utility_account_id` | Platform/root AWS account ID (where Route53 parent zone lives) | `string` | - | yes |
| `token` | HCP Terraform organization token | `string` | - | yes |
| `pgp_key` | Base64-encoded PGP public key for encrypting breakglass password | `string` | `null` | no |
