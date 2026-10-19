output "falcon_registration" {
  description = "Falcon registration details for the AWS Organization"
  value = {
    organization_id                    = crowdstrike_cloud_aws_account.this.organization_id
    management_account_id              = crowdstrike_cloud_aws_account.this.account_id
    is_organization_management_account = crowdstrike_cloud_aws_account.this.is_organization_management_account
    iam_role_name                      = crowdstrike_cloud_aws_account.this.iam_role_name
    intermediate_role_arn              = crowdstrike_cloud_aws_account.this.intermediate_role_arn
    eventbus_arn                       = crowdstrike_cloud_aws_account.this.eventbus_arn
    agentless_scanning_role_name       = crowdstrike_cloud_aws_account.this.agentless_scanning_role_name
  }
}

output "external_id" {
  description = "The external ID CrowdStrike uses to assume the IAM roles in each account"
  value       = crowdstrike_cloud_aws_account.this.external_id
  sensitive   = true
}

output "onboarded_accounts" {
  description = "AWS accounts deployed by this configuration and their agentless scanning role"
  value = {
    management = {
      account_id                               = var.account_id
      agentless_scanning_integration_role_name = module.fcs_management_account.agentless_scanning_integration_role_name
    }
    scanner_host = {
      account_id                               = local.scanner_host_account_id
      agentless_scanning_integration_role_name = module.fcs_scanner_host_account.agentless_scanning_integration_role_name
    }
    child_account_1 = {
      account_id                               = local.child_account_id
      agentless_scanning_integration_role_name = module.fcs_child_account_1.agentless_scanning_integration_role_name
    }
  }
}

output "regions" {
  description = "Regions used by this configuration"
  value = {
    primary_region              = local.primary_region
    cloudtrail_region           = local.cloudtrail_region
    realtime_visibility_regions = local.realtime_visibility_regions
    agentless_scanning_regions  = local.agentless_scanning_regions
  }
}
