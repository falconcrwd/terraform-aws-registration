# FCS AWS Organization Registration Tutorial (SSO Profile + Cross-Account Role, Dedicated Scanner Host)

This example registers an AWS Organization with CrowdStrike Falcon Cloud Security (FCS) entirely from Terraform,
without using the registration wizard in the Falcon console. It onboards three accounts:

| Account | Module | How Terraform authenticates | Role in this example |
|---|---|---|---|
| Management account (`TF_VAR_account_id`) | `fcs_management_account` (`modules/aws-profile`) | Directly with an AWS CLI / SSO profile | Org registration in Falcon, scan target |
| Scanner host account (`local.scanner_host_account_id`) | `fcs_scanner_host_account` (`modules/aws-role`) | Assumes `aws_role_name` (e.g. `OrganizationAccountAccessRole`) | Hosts the agentless scanning infrastructure for the whole org |
| Child account (`local.child_account_id`) | `fcs_child_account_1` (`modules/aws-role`) | Assumes `aws_role_name` | Scan target |

- The management account uses an SSO profile directly, so you do **not** need a role to assume in the management account.
  `OrganizationAccountAccessRole` only exists in member accounts that AWS Organizations created, never in the management account itself.
- Agentless scanning (DSPM and vulnerability scanning) uses **cross-account scanning** with a **dedicated scanner host account**, not the management account.
- Real-time visibility, agentless scanning, the CloudTrail region, and resource name prefixes/suffixes are all set explicitly and consistently across every account.

## Features Enabled

- Asset Inventory (IOMs)
- Real-time Visibility and Detection (EventBridge, using an existing organization CloudTrail)
- Identity Protection (IDP)
- Agentless Scanning:
    - Data Security Posture Management (DSPM)
    - Vulnerability Scanning
- Sensor Management is **disabled** (`enable_sensor_management = false`)

## Architecture

```
                      ┌────────────────────────────────────────────┐
                      │ Falcon: crowdstrike_cloud_aws_account.this │
                      │ registers the organization (management ID) │
                      └─────────────────────┬──────────────────────┘
       external_id, intermediate_role_arn, iam_role_name, eventbus_arn, agentless_scanning_role_name
            ┌───────────────────────────────┼──────────────────────────────┐
            ▼                               ▼                              ▼
  Management account             Scanner host account               Child account(s)
  (SSO profile)                  (assume aws_role_name)             (assume aws_role_name)
  - reader role                  - reader role                      - reader role
  - EventBridge role + rules     - EventBridge role + rules         - EventBridge role + rules
  - scanning roles + KMS keys    - scanning roles + KMS keys        - scanning roles + KMS keys
            │                    - per scanning region: VPC,                   │
            │                      subnets, NAT gateway, endpoints,            │
            │                      security groups, scanners  ◄────────────────┘
            └──────────────────────────────►   (scans all accounts, same region)
```

`crowdstrike_cloud_aws_account.this` creates nothing in AWS. It calls the Falcon Cloud Registration API to register the
organization (with `organization_id` set, `account_id` must be the management account). It returns the values that every
AWS module needs to create matching roles and trust policies. Because the modules use those outputs, Terraform always
creates the Falcon registration first.

## What It Creates

With the default settings in `main.tf` this deploys about 227 resources:

| Where | What |
|---|---|
| Falcon | One organization registration, with resource names prefixed `cs-` and suffixed `-cspm` |
| Every onboarded account | Asset inventory reader role; EventBridge IAM role, plus IOA and read-only EventBridge rules and targets in each `realtime_visibility_regions` region; agentless scanning integration and scanner roles; one KMS key per agentless scanning region; agentless scanning SSM parameters and client secret in `primary_region` |
| Scanner host account only, **per region in `agentless_scanning_regions`** | VPC, 4 subnets, internet gateway, NAT gateway with Elastic IP, route tables, network ACL, 2 security groups, 2 VPC endpoints, DB and Redshift subnet groups, KMS key, and the scanner instance profile (once per account) |
| Scanner host account, at scan time (**not managed by Terraform**) | `CrowdStrike-DataScanner` EC2 instances, which CrowdStrike launches into the scanner VPCs and manages itself |

### Region settings

All region settings live in the `locals` block of `main.tf`:

| Local | Purpose | Value |
|---|---|---|
| `primary_region` | Region for account-wide resources created once per account. It is the default AWS provider region, holds the EventBridge IAM role, sets the STS endpoint, and is the agentless scanning "root region" (SSM parameters, client secret). It can be any enabled region and does **not** need to be `us-east-1`. | `us-east-1` |
| `cloudtrail_region` | Recorded in Falcon as the region of your CloudTrail S3 bucket. With EventBridge ingestion it does not affect deployment, but the provider requires it. Set it to your org trail's bucket region. | `ap-southeast-1` |
| `realtime_visibility_regions` | Where EventBridge rules forward CloudTrail events to CrowdStrike. **Always include `us-east-1`**, because AWS delivers global-service events (IAM, Organizations, global STS) only there. Also include `primary_region`. | `us-east-1`, `ap-southeast-1`, `ap-southeast-2` |
| `agentless_scanning_regions` | Where DSPM and vulnerability scanning run. Scanning is per region, so data stores and VMs in other regions are not scanned. Maximum 15 regions per account. | `ap-southeast-1`, `ap-southeast-2` |

## Why Scanner Resources Belong in a Separate Account

With cross-account scanning, one **host** account runs the scanners for the whole organization. The other accounts only
get IAM roles and KMS keys, so they don't need their own VPCs or NAT gateways. Choosing the right host matters:

- **Don't use the management account.** Whoever controls the management account can control the whole organization:
  accounts, SCPs, and access into every member account. AWS recommends running only tasks there that *require* the management account.
- **Sensitive data is processed on the host.** DSPM scanners read and classify data from every target account (for example PII
  and card numbers). Keep that processing out of your most privileged account, and out of production workload accounts.
- **The host adds attack surface.** It gets VPCs, NAT gateways with internet egress, VPC endpoints, and EC2 instances with
  permissions to work with snapshots and data shared from other accounts.
- **Cost and ownership are clearer.** NAT gateway and scanner compute costs land on a security cost center, not on a workload or management bill.

The recommended host is a dedicated **Security Tooling** account, as in the AWS Security Reference Architecture.
CrowdStrike's own documentation also recommends limiting use of the management account where possible.

### Scanner resources exist in every agentless scanning region

The host account gets a complete scanning environment (VPC, subnets, NAT gateway, endpoints, security groups, subnet
groups, KMS key) in **each region listed in `agentless_scanning_regions`**. DSPM and vulnerability scanning share this one
list, and scanning is per region: the scanners in a region scan data stores and VMs in that same region across all target
accounts. Every region you add therefore adds another VPC, NAT gateway, and set of endpoints in the host account, and
another KMS key in each target account. NAT gateways and VPC endpoints are billed even when idle, so only list regions
that actually contain data or workloads you want scanned.

The scanner EC2 instances are not created by Terraform. CrowdStrike launches them into these VPCs through the integration
role when scans run, and manages how long they run.

## Prerequisites

1. [AWS CLI](https://docs.aws.amazon.com/cli/latest/userguide/install-cliv2.html) and
   [Terraform](https://learn.hashicorp.com/tutorials/terraform/install-cli) >= 1.5 installed
2. CrowdStrike API client ID and secret with the Cloud Security registration scopes (see [Pre-requisites](../../README.md#pre-requisites))
3. An AWS Organization with:
    - an AWS CLI / SSO profile for the management account
    - a role in each member account (scanner host and children) that the management credentials can assume.
      `OrganizationAccountAccessRole` exists by default in accounts created through AWS Organizations.
4. An organization CloudTrail trail that is **logging**. Real-time visibility and IDP need it. Check with
   `aws cloudtrail get-trail-status --name <trail> --region <home region>` and turn it on with `aws cloudtrail start-logging`.
5. Enough VPC, NAT gateway, and Elastic IP quota in the scanner host account for each agentless scanning region
   (one VPC, one NAT gateway, and one EIP per region)

## Deploy

1. Set the account IDs in the `locals` block of `main.tf`:

```hcl
  child_account_id        = "222222222222" # member account to onboard
  scanner_host_account_id = "333333333333" # dedicated security tooling account
```

   Then adjust `cloudtrail_region`, `realtime_visibility_regions`, and `agentless_scanning_regions` for your environment.

2. Set the required environment variables. Run them in the **same shell** you run Terraform from:

```sh
export AWS_PROFILE=<management account profile>         # base credentials for the aws-role modules
export TF_VAR_aws_profile=<management account profile>  # used directly by the management account module
export TF_VAR_aws_role_name=OrganizationAccountAccessRole
export TF_VAR_account_id=<management account id>        # e.g. 111111111111
export TF_VAR_organization_id=<organization id>         # e.g. o-exampleorgid
export TF_VAR_falcon_client_id=<your client id>
export TF_VAR_falcon_client_secret=<your client secret>
```

   If you use AWS IAM Identity Center, run `aws sso login --profile <profile>` first, and make sure the session will last longer than the apply.

3. Initialize, review the plan, and apply:

```sh
terraform init
terraform plan -out=tfplan
terraform apply tfplan
```

   Saved plan files contain variable values, including `falcon_client_secret`, in plain text. Delete `tfplan` after applying
   and don't commit it. The same applies to `terraform.tfstate`. Consider a remote backend with encryption and locking for real use.

4. Check the result:

```sh
terraform output onboarded_accounts
terraform output falcon_registration
```

   In the Falcon console, go to **Cloud connections > AWS**. Each feature shows **Pending** at first, and then
   **Operational** after a few minutes. Real-time visibility stays pending until the org trail is logging.

## Adding Child Accounts

Each additional member account needs its own module block. Falcon discovers every account in the organization, but only
accounts with a module block get the CrowdStrike roles and EventBridge rules.

1. Add the account ID to `locals` in `main.tf`:

```hcl
  child_account_2_id = "444444444444"
```

2. Copy the `fcs_child_account_1` module block, give it a unique name, and point it at the new account ID. Keep both
   `agentless_scanning_host_*` lines so the account is scanned from the scanner host account:

```hcl
module "fcs_child_account_2" {
  source        = "../../modules/aws-role/"
  aws_role_name = var.aws_role_name
  account_id    = local.child_account_2_id
  # ... every other argument identical to fcs_child_account_1 ...
  agentless_scanning_host_account_id = local.scanner_host_account_id
  agentless_scanning_host_role_name  = module.fcs_scanner_host_account.agentless_scanning_integration_role_name
}
```

3. Add the account to the `onboarded_accounts` output in `outputs.tf`:

```hcl
    child_account_2 = {
      account_id                               = local.child_account_2_id
      agentless_scanning_integration_role_name = module.fcs_child_account_2.agentless_scanning_integration_role_name
    }
```

4. Run `terraform plan`. You should only see new resources for the new account (about 56 with the default settings),
   and no changes to existing accounts. Then apply.

Notes:

- The new account needs the role named in `TF_VAR_aws_role_name`, and your management credentials must be allowed to assume it.
  Test with `aws sts assume-role --role-arn arn:aws:iam::<id>:role/<role> --role-session-name test`.
- `agentless_scanning_host_role_name` references the host module's output. That makes Terraform finish the scanner host
  before any target account, which CrowdStrike requires.
- The new account is scanned only in `agentless_scanning_regions`. Data in other regions is not scanned.
- Each module configures about 30 regional AWS providers, so every extra account makes `plan` and `apply` noticeably slower.

## Things to Avoid

- **Don't delete or edit the registration in the Falcon console.** Terraform manages it, so treat the console as read-only.
  If you delete it in the console, the next `plan` fails with `Failed to read ... API call succeeded but returned no data`.
  To recover, run `terraform state rm crowdstrike_cloud_aws_account.this` and then apply again.
- **Don't omit `realtime_visibility.cloudtrail_region`.** The provider requires it whenever the `realtime_visibility` block is set.
- **Don't run Terraform from a shell without `AWS_PROFILE`.** The `aws-role` modules use whatever credentials are in the
  environment as their starting point. Without them you get `No valid credential sources found ... 169.254.169.254`.
- **Keep the scanner role name consistent.** Target accounts trust `CrowdStrikeAgentlessScanningScannerRole` in the host account,
  so keep the default name, or set the same custom name in every module.

## Destroy

To remove everything this example created, including the Falcon registration:

```sh
terraform destroy
```

Before destroying, terminate any running CrowdStrike scanner instances in the scanner host account. They are not in
Terraform state, and they block deletion of the scanner VPCs:

```sh
aws ec2 describe-instances --region <region> \
  --filters Name=tag:ProvisionedBy,Values=CrowdStrike Name=instance-state-name,Values=pending,running,stopped \
  --query 'Reservations[].Instances[].InstanceId' --output text
```

After the destroy, the CrowdStrike KMS keys stay in **pending deletion** for the AWS waiting period (7-30 days).
Keys in that state are not billed.
