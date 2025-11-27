#########################################################
# VARIABLES
#########################################################
# Define the region for AWS resources
variable "aws_region" {
  type    = string
  default = "eu-west-2"
}
# Define the profile to connect to AWS resources
variable "aws_profile" {
  description = "The AWS profile to use for running the code"
  type        = string
  default     = "default"
}

# IAM Variables
variable "ops_users_list" {
  description = "List of Operations user names"
  type        = list(string)
  default = [
    "ops_user2",
    "ops_user3"
  ]
}

variable "admin_users_list" {
  description = "List of IAM Admin user names"
  type        = list(string)
  default     = ["admin_user1"]
}

#########################################################
# IAM GROUPS, USERS
#########################################################
resource "aws_iam_group" "admin_group" {
  name = "admins"
}

resource "aws_iam_group" "ops_group" {
  name = "operations"
}

resource "aws_iam_user" "admins" {
  for_each = toset(var.admin_users_list)
  name     = each.key
}

resource "aws_iam_user" "operations" {
  for_each = toset(var.ops_users_list)
  name     = each.key
}

resource "aws_iam_group_membership" "admins_membership" {
  name  = "admins_membership"
  users = [for u in aws_iam_user.admins : u.name]
  group = aws_iam_group.admin_group.name
}
# Attach full admin policy to admin group
resource "aws_iam_group_policy_attachment" "admin_policy" {
  group      = aws_iam_group.admin_group.name
  policy_arn = "arn:aws:iam::aws:policy/AdministratorAccess"
}

resource "aws_iam_group_membership" "ops_membership" {
  name  = "ops_membership"
  users = [for u in aws_iam_user.operations : u.name]
  group = aws_iam_group.ops_group.name
}

#  Create console passwords (login profiles)
resource "aws_iam_user_login_profile" "ops_user_passwords" {
  for_each                = aws_iam_user.operations
  user                    = each.value.name
  password_length         = 16
  password_reset_required = true
}

resource "aws_iam_user_login_profile" "admin_user_passwords" {
  for_each                = aws_iam_user.admins
  user                    = each.value.name
  password_length         = 16
  password_reset_required = true
}


#########################################################
# OPERATIONS USER ROLE + POLICIES
#########################################################
data "aws_caller_identity" "current" {}

# Create Trust policy on the role, this ensures only members of the operations group can assume the role
# This is the standard AWS pattern:
# - Trust policy: who could assume
# - IAM policy: who is allowed to call sts:AssumeRole

resource "aws_iam_role" "ops_user_role" {
  name        = "OperationsUserRole"
  description = "Custom - Role for operations users with limited permissions"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Principal = {
          AWS = "arn:aws:iam::${data.aws_caller_identity.current.account_id}:root"
        }
        Action = "sts:AssumeRole"
      }
    ]
  })
}

# IAM permissions on the user/group to call AssumeRole
resource "aws_iam_policy" "allow_assume_ops_role" {
  name        = "AllowAssumeOpsRole"
  description = "Custom - Allows operations group to assume the OperationsUserRole"

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect   = "Allow"
        Action   = "sts:AssumeRole"
        Resource = aws_iam_role.ops_user_role.arn
      }
    ]
  })
}

# Attach it to the group:
resource "aws_iam_group_policy_attachment" "ops_group_assume" {
  group      = aws_iam_group.ops_group.name
  policy_arn = aws_iam_policy.allow_assume_ops_role.arn
}

# EC2 Describe permissions
data "aws_iam_policy_document" "ops_custom_ec2_describe" {
  statement {
    sid    = "EC2AllApiCalls"
    effect = "Allow"
    actions = [
      "ec2:Describe*"
    ]
    resources = ["*"]
  }
}

# SSM Session permissions
data "aws_iam_policy_document" "ops_custom_ssm_sessions" {
  statement {
    sid    = "AllowSSMAllInstances"
    effect = "Allow"
    actions = [
      "ssm:*",
      "ssm-guiconnect:*"
    ]
    resources = ["*"]
  }
}

data "aws_iam_policy_document" "ops_custom_ssm_messages" {
  statement {
    sid    = "AllowSSMMessages"
    effect = "Allow"
    actions = [
      "ssmmessages:*",
      "ec2messages:*"
    ]
    resources = ["*"]
  }
}

data "aws_iam_policy_document" "ops_custom_cloudwatch" {
  statement {
    sid    = "AllowcloudwatchAll"
    effect = "Allow"
    actions = [
      "cloudwatch:Describe*",
      "cloudwatch:List*",
      "cloudwatch:Get*"
    ]
    resources = ["*"]
  }
}

# S3 Read-only permissions
data "aws_iam_policy_document" "ops_custom_s3_readonly" {
  statement {
    sid    = "AllowS3ReadOnly"
    effect = "Allow"
    actions = [
      "s3:GetObject",
      "s3:GetObjectVersion",
      "s3:ListBucket",
      "s3:ListAllMyBuckets",
      "s3:ListBucketVersions",
      "s3:GetBucketLocation"
    ]
    resources = [
      "arn:aws:s3:::*",
      "arn:aws:s3:::*/*"
    ]
  }
}

# Other Permissions combined
data "aws_iam_policy_document" "ops_user_other_permissions" {
  statement {
    sid    = "AllowBasicConsoleInfo"
    effect = "Allow"
    actions = [
      "iam:GetAccountSummary",
      "iam:ListAccountAliases",

      # Support Center (read-only)
      "support:DescribeCases",
      "support:DescribeCommunications",
      "support:DescribeServices",
      "support:DescribeSeverityLevels",
      "support:DescribeSupportLevel",
      "support:DescribeTrustedAdvisorChecks",
      "support:DescribeTrustedAdvisorCheckSummaries",

      # Billing console requires this (read-only)
      "aws-portal:ViewAccount",
      "aws-portal:ViewBilling",
      "aws-portal:ViewUsage",
      "aws-portal:ViewPaymentMethods",

      # Clopudtrail events.
      "cloudtrail:DescribeTrails",
      "cloudtrail:GetTrailStatus",
      "cloudtrail:ListTrails",

      # Region and Console settings
      "account:ListRegions",
      "account:GetAccountInformation",
      "account:GetRegionOptStatus"
    ]
    resources = ["*"]
  }
}


data "aws_iam_policy_document" "ops_user_permissions" {
  source_policy_documents = [
    data.aws_iam_policy_document.ops_custom_ec2_describe.json,
    data.aws_iam_policy_document.ops_custom_ssm_sessions.json,
    data.aws_iam_policy_document.ops_custom_ssm_messages.json,
    data.aws_iam_policy_document.ops_custom_s3_readonly.json,
    data.aws_iam_policy_document.ops_user_other_permissions.json,
    data.aws_iam_policy_document.ops_custom_cloudwatch.json
  ]
}

# Create an IAM policy from this document
resource "aws_iam_policy" "ops_user_custom_policy" {
  name        = "OperationsUserPolicy"
  description = "Custom - Permissions for operations users after assuming the OperationsUserRole"
  policy      = data.aws_iam_policy_document.ops_user_permissions.json
}

# Attach the policy to your role
resource "aws_iam_role_policy_attachment" "ops_role_permissions" {
  role       = aws_iam_role.ops_user_role.name
  policy_arn = aws_iam_policy.ops_user_custom_policy.arn
}

# IAM Policy to allow ops users to list and get their own role info.
resource "aws_iam_policy" "ops_minimal_role_listing" {
  name        = "AllowOpsMinimalRoleListing"
  description = "Custom - IAM Policy to allow ops users to list and get their own role info."
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "AllowViewSpecificRole"
        Effect = "Allow"
        Action = [
          "iam:ListRoles",
          "iam:GetRole"
        ]
        Resource = "arn:aws:iam::*:user/$${aws:username}"
      }
    ]
  })
}
# Attach it to the group:
resource "aws_iam_group_policy_attachment" "ops_minimal_role_listing_attach" {
  group      = aws_iam_group.ops_group.name
  policy_arn = aws_iam_policy.ops_minimal_role_listing.arn
}

resource "aws_iam_policy" "allow_user_self_management" {
  name        = "AllowUserSelfManagement"
  description = "Custom - IAM Policy to allow ops users to do Self management of their own IAM user account."
  policy = jsonencode({
    Version = "2012-10-17",
    Statement = [
      {
        Sid      = "AllowGetOwnUser",
        Effect   = "Allow",
        Action   = "iam:GetUser",
        Resource = "arn:aws:iam::*:user/$${aws:username}"
      },
      {
        Sid    = "AllowManageOwnPassword",
        Effect = "Allow",
        Action = [
          "iam:GetLoginProfile",
          "iam:UpdateLoginProfile",
          "iam:ChangePassword"
        ],
        Resource = "arn:aws:iam::*:user/$${aws:username}"
      },
      {
        Sid    = "AllowManageOwnMFA",
        Effect = "Allow",
        Action = [
          "iam:ListMFADevices",
          "iam:CreateVirtualMFADevice",
          "iam:EnableMFADevice",
          "iam:ResyncMFADevice",
          "iam:DeactivateMFADevice",
          "iam:DeleteVirtualMFADevice"
        ],
        Resource = [
          "arn:aws:iam::*:user/$${aws:username}",
          "arn:aws:iam::*:mfa/$${aws:username}"
        ]
      },
      {
        Sid    = "AllowManageOwnAccessKeys",
        Effect = "Allow",
        Action = [
          "iam:ListAccessKeys",
          "iam:CreateAccessKey",
          "iam:DeleteAccessKey",
          "iam:UpdateAccessKey"
        ],
        Resource = "arn:aws:iam::*:user/$${aws:username}"
      },
      {
        Sid    = "AllowManageOwnSigningCertificates",
        Effect = "Allow",
        Action = [
          "iam:ListSigningCertificates",
          "iam:UploadSigningCertificate",
          "iam:DeleteSigningCertificate"
        ],
        Resource = "arn:aws:iam::*:user/$${aws:username}"
      }
    ]
  })
}
# Attach it to the group:
resource "aws_iam_group_policy_attachment" "ops_group_self_manage_attach" {
  group      = aws_iam_group.ops_group.name
  policy_arn = aws_iam_policy.allow_user_self_management.arn
}

#########################################################
# OUTPUTS
#########################################################

# Friendly AWS Console URL for your account
output "aws_console_login_url" {
  value = "https://${data.aws_caller_identity.current.account_id}.signin.aws.amazon.com/console"
}

# Admin user names
output "admin_users" {
  value = [for u in aws_iam_user.admins : u.name]
}

# Operations user names
output "ops_users" {
  value = [for u in aws_iam_user.operations : u.name]
}

# Operations user role ARN (to be assumed)
output "ops_role_arn" {
  value = aws_iam_role.ops_user_role.arn
}

# Custom permissions policy ARN for ops users
output "ops_user_custom_policy_arn" {
  value = aws_iam_policy.ops_user_custom_policy.arn
}

# AllowAssumeOpsRole policy ARN
output "ops_assume_role_policy_arn" {
  value = aws_iam_policy.allow_assume_ops_role.arn
}

# Group names
output "iam_groups" {
  value = {
    admin_group = aws_iam_group.admin_group.name
    ops_group   = aws_iam_group.ops_group.name
  }
}

# (Optional) Initial console passwords for operations users
# WARNING: These appear in Terraform output and state file.
output "ops_user_console_passwords" {
  value     = { for u, p in aws_iam_user_login_profile.ops_user_passwords : u => p.password }
  sensitive = true
}
output "admin_user_console_passwords" {
  value     = { for u, p in aws_iam_user_login_profile.admin_user_passwords : u => p.password }
  sensitive = true
}
