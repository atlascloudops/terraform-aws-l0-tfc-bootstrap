Member account onboarding + OIDC federation setup

## Overview

This Terraform module configures HCP Terraform (Terraform Cloud) OIDC federation for AWS member accounts. It creates:
- AWS IAM OIDC provider for HCP Terraform
- IAM role with trust policy for OIDC authentication
- Breakglass IAM user for emergency console access
- HCP Terraform variable set with AWS OIDC configuration

## Multi-Region Idempotency

This module is **fully idempotent** across multiple regional deployments in the same AWS account using data source existence checks. Since IAM resources are **global** (not region-specific), the module automatically detects and uses existing resources.

### How It Works

The module uses data sources with `try()` to check if global IAM resources already exist:
1. **Data source lookup**: Attempts to fetch existing resources (OIDC provider, IAM role, IAM user, TFE variable set)
2. **Existence check**: Uses `try()` in locals to determine if each resource exists
3. **Conditional creation**: Resources are only created (count = 1) if they don't already exist
4. **Unified reference**: Locals provide a single reference point whether the resource is existing or newly created

This approach works for both:
- ✅ **Brand new accounts**: Data sources return null, resources are created
- ✅ **Existing deployments**: Data sources find existing resources, creation is skipped

### Usage Pattern

The same configuration works for **all regional deployments**:

```hcl
module "tfc_bootstrap" {
  source = "./terraform-aws-l0-tfc-bootstrap"

  region                      = "us-east-1"  # or us-west-2, eu-west-1, etc.
  member_account_id           = "123456789012"
  tfc_organization_name       = "my-org"
  tfc_project_name            = "my-project"
  platform_utility_account_id = "999888777666"
  token                       = var.tfc_token
}
```

**First deployment** (e.g., us-east-1):
- Creates all global IAM resources
- Creates TFE variable set

**Subsequent deployments** (e.g., us-west-2, eu-west-1):
- Automatically imports existing global IAM resources
- Shares the same TFE variable set (no duplicates)
- No `EntityAlreadyExists` errors

## Variables

| Name | Description | Type | Default | Required |
|------|-------------|------|---------|----------|
| `region` | AWS region where resources will be created | `string` | `"us-east-1"` | no |
| `member_account_id` | AWS member account ID where OIDC provider and role will be created | `string` | - | yes |
| `tfc_organization_name` | HCP Terraform organization name | `string` | - | yes |
| `tfc_project_name` | HCP Terraform project name | `string` | - | yes |
| `platform_utility_account_id` | Platform/root AWS account ID (where Route53 parent zone lives) | `string` | - | yes |
| `token` | HCP Terraform organization token | `string` | - | yes |
| `pgp_key` | Base64-encoded PGP public key for encrypting breakglass password | `string` | `null` | no |

## Requirements

- Terraform >= 1.5.0 (required for data source lifecycle postconditions)
- AWS provider ~> 5.31.0
- TFE provider ~> 0.70.0

## How Idempotency Works

When you run this module in multiple regions:

**First run (us-east-1)**:
- Data sources attempt to find existing resources → return null
- `try()` evaluates to false for all existence checks
- All resources created with `count = 1`
- Outputs show newly created resources

**Second run (us-west-2)**:
- Data sources find existing global resources → return resource data
- `try()` evaluates to true for existence checks
- All resources skipped with `count = 0`
- Outputs show existing resources via locals
- No `EntityAlreadyExists` errors!
