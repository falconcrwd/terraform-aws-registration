locals {
  # region for account-wide resources created once per account: the default AWS provider region
  # (IAM roles, agentless scanning Secrets Manager secret and SSM parameters), the EventBridge IAM role,
  # and the STS endpoint used to assume aws_role_name. Unrelated to where CloudTrail logs are stored.
  primary_region                        = "us-east-1"
  enable_realtime_visibility            = true
  cloudtrail_region                     = "ap-southeast-1" # region of the org trail's S3 bucket
  child_account_id                      = "222222222222"   # replace with a member account ID to onboard
  scanner_host_account_id               = "333333333333"   # replace with the account that hosts agentless scanning resources for the org
  enable_idp                            = true
  realtime_visibility_regions           = ["us-east-1", "ap-southeast-1", "ap-southeast-2"] # us-east-1 receives global service (IAM, Organizations) events
  enable_sensor_management              = false
  enable_dspm                           = true
  enable_vulnerability_scanning         = true
  agentless_scanning_regions            = ["ap-southeast-1", "ap-southeast-2"]
  agentless_scanning_create_nat_gateway = var.agentless_scanning_create_nat_gateway
  dspm_s3_access                        = var.dspm_s3_access
  dspm_dynamodb_access                  = var.dspm_dynamodb_access
  dspm_rds_access                       = var.dspm_rds_access
  dspm_redshift_access                  = var.dspm_redshift_access
  dspm_ebs_access                       = var.dspm_ebs_access
  resource_prefix                       = "cs-"
  resource_suffix                       = "-cspm"
}

provider "crowdstrike" {
  client_id     = var.falcon_client_id
  client_secret = var.falcon_client_secret
}

# Provision AWS account in Falcon.
resource "crowdstrike_cloud_aws_account" "this" {
  account_id           = var.account_id
  organization_id      = var.organization_id
  resource_name_prefix = local.resource_prefix
  resource_name_suffix = local.resource_suffix
  asset_inventory = {
    enabled = true
  }

  realtime_visibility = {
    enabled           = local.enable_realtime_visibility
    cloudtrail_region = local.cloudtrail_region
  }

  idp = {
    enabled = local.enable_idp
  }

  sensor_management = {
    enabled = local.enable_sensor_management
  }

  dspm = {
    enabled = local.enable_dspm
  }

  vulnerability_scanning = {
    enabled = local.enable_vulnerability_scanning
  }
}

# management account uses the SSO profile directly instead of assuming a role
module "fcs_management_account" {
  source                        = "github.com/CrowdStrike/terraform-aws-cloud-registration//modules/aws-profile?ref=v0.7.13"
  aws_profile                   = var.aws_profile
  falcon_client_id              = var.falcon_client_id
  falcon_client_secret          = var.falcon_client_secret
  account_id                    = var.account_id
  organization_id               = var.organization_id
  primary_region                = local.primary_region
  enable_sensor_management      = local.enable_sensor_management
  enable_realtime_visibility    = local.enable_realtime_visibility
  enable_idp                    = local.enable_idp
  realtime_visibility_regions   = local.realtime_visibility_regions
  enable_dspm                   = local.enable_dspm
  enable_vulnerability_scanning = local.enable_vulnerability_scanning
  agentless_scanning_regions    = local.agentless_scanning_regions
  vpc_cidr_block                = var.vpc_cidr_block

  iam_role_name                         = crowdstrike_cloud_aws_account.this.iam_role_name
  external_id                           = crowdstrike_cloud_aws_account.this.external_id
  intermediate_role_arn                 = crowdstrike_cloud_aws_account.this.intermediate_role_arn
  eventbus_arn                          = crowdstrike_cloud_aws_account.this.eventbus_arn
  agentless_scanning_role_name          = crowdstrike_cloud_aws_account.this.agentless_scanning_role_name
  agentless_scanning_create_nat_gateway = local.agentless_scanning_create_nat_gateway
  dspm_s3_access                        = local.dspm_s3_access
  dspm_dynamodb_access                  = local.dspm_dynamodb_access
  dspm_rds_access                       = local.dspm_rds_access
  dspm_redshift_access                  = local.dspm_redshift_access
  dspm_ebs_access                       = local.dspm_ebs_access
  resource_prefix                       = local.resource_prefix
  resource_suffix                       = local.resource_suffix
  agentless_scanning_host_account_id    = local.scanner_host_account_id                                            # scanned by the agentless scanning host account
  agentless_scanning_host_role_name     = module.fcs_scanner_host_account.agentless_scanning_integration_role_name # creates dependency on agentless scanning host module
}

# agentless scanning host account: deploys the scanner VPCs, NAT gateways and scanners
# do not set agentless_scanning_host_* here, which is what makes this account the host
module "fcs_scanner_host_account" {
  source                        = "github.com/CrowdStrike/terraform-aws-cloud-registration//modules/aws-role?ref=v0.7.13"
  aws_role_name                 = var.aws_role_name
  falcon_client_id              = var.falcon_client_id
  falcon_client_secret          = var.falcon_client_secret
  account_id                    = local.scanner_host_account_id
  organization_id               = var.organization_id
  primary_region                = local.primary_region
  enable_sensor_management      = local.enable_sensor_management
  enable_realtime_visibility    = local.enable_realtime_visibility
  enable_idp                    = local.enable_idp
  realtime_visibility_regions   = local.realtime_visibility_regions
  enable_dspm                   = local.enable_dspm
  enable_vulnerability_scanning = local.enable_vulnerability_scanning
  agentless_scanning_regions    = local.agentless_scanning_regions
  vpc_cidr_block                = var.vpc_cidr_block

  iam_role_name                         = crowdstrike_cloud_aws_account.this.iam_role_name
  external_id                           = crowdstrike_cloud_aws_account.this.external_id
  intermediate_role_arn                 = crowdstrike_cloud_aws_account.this.intermediate_role_arn
  eventbus_arn                          = crowdstrike_cloud_aws_account.this.eventbus_arn
  agentless_scanning_role_name          = crowdstrike_cloud_aws_account.this.agentless_scanning_role_name
  agentless_scanning_create_nat_gateway = local.agentless_scanning_create_nat_gateway
  dspm_s3_access                        = local.dspm_s3_access
  dspm_dynamodb_access                  = local.dspm_dynamodb_access
  dspm_rds_access                       = local.dspm_rds_access
  dspm_redshift_access                  = local.dspm_redshift_access
  dspm_ebs_access                       = local.dspm_ebs_access
  resource_prefix                       = local.resource_prefix
  resource_suffix                       = local.resource_suffix
}

# for each child account you want to onboard
# - duplicate this module and give it a unique name
# - replace `account_id` with the child account ID (the module assumes `aws_role_name` in that account)
# - keep both agentless_scanning_host_* lines so the account is scanned from the scanner host account
# - add the account to `onboarded_accounts` in outputs.tf
module "fcs_child_account_1" {
  source                        = "github.com/CrowdStrike/terraform-aws-cloud-registration//modules/aws-role?ref=v0.7.13"
  aws_role_name                 = var.aws_role_name
  falcon_client_id              = var.falcon_client_id
  falcon_client_secret          = var.falcon_client_secret
  account_id                    = local.child_account_id
  organization_id               = var.organization_id
  primary_region                = local.primary_region
  enable_sensor_management      = local.enable_sensor_management
  enable_realtime_visibility    = local.enable_realtime_visibility
  enable_idp                    = local.enable_idp
  realtime_visibility_regions   = local.realtime_visibility_regions
  enable_dspm                   = local.enable_dspm
  enable_vulnerability_scanning = local.enable_vulnerability_scanning
  agentless_scanning_regions    = local.agentless_scanning_regions
  vpc_cidr_block                = var.vpc_cidr_block

  iam_role_name                         = crowdstrike_cloud_aws_account.this.iam_role_name
  external_id                           = crowdstrike_cloud_aws_account.this.external_id
  intermediate_role_arn                 = crowdstrike_cloud_aws_account.this.intermediate_role_arn
  eventbus_arn                          = crowdstrike_cloud_aws_account.this.eventbus_arn
  agentless_scanning_role_name          = crowdstrike_cloud_aws_account.this.agentless_scanning_role_name
  agentless_scanning_create_nat_gateway = local.agentless_scanning_create_nat_gateway
  dspm_s3_access                        = local.dspm_s3_access
  dspm_dynamodb_access                  = local.dspm_dynamodb_access
  dspm_rds_access                       = local.dspm_rds_access
  dspm_redshift_access                  = local.dspm_redshift_access
  dspm_ebs_access                       = local.dspm_ebs_access
  resource_prefix                       = local.resource_prefix
  resource_suffix                       = local.resource_suffix
  agentless_scanning_host_account_id    = local.scanner_host_account_id                                            # scanned by the agentless scanning host account
  agentless_scanning_host_role_name     = module.fcs_scanner_host_account.agentless_scanning_integration_role_name # creates dependency on agentless scanning host module
}
