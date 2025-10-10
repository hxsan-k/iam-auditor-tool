#!/bin/bash

set -uo pipefail

BUCKET="iam-audit-reports-hasan"
SNS_TOPIC_ARN="arn:aws:sns:eu-west-2:0123456789012:iam-audit-reports-hasan" # Account ID redacted
ADMIN_POLICY_NAME="AdministratorAccess"

timestamp=$(date +"%Y-%m-%d_%H-%M-%S")
region=${AWS_REGION:-eu-west-2}
report="iam-audit-$timestamp.txt"

# Check that the EC2 instance actually has AWS creds/role attached
account_id=$(aws sts get-caller-identity --query Account --output text 2>/dev/null || true)
if [[ -z "$account_id" || "$account_id" == "None" ]]
then
  echo "No AWS credentials found. Make sure the EC2 instance has the right IAM role." >&2
  exit 1
fi

# Variables to track progress and results
audit_failed="false"
findings_count=0
alert_needed="false"
declare -a findings

{
  echo "IAM Permissions Audit Report"
  echo "Account ID: $account_id"
  echo "Region: $region"
  echo "Date: $timestamp"
  echo "----------------------------------"
} > "$report"

echo "Created report file: $report"

# Functions to check users, roles, and groups for admin access
check_user() {
  local user="$1"
  local count
  count=$(aws iam list-attached-user-policies \
            --user-name "$user" \
            --query "length(AttachedPolicies[?PolicyName=='${ADMIN_POLICY_NAME}'])" \
            --output text 2>/dev/null || echo "__ERR__")

  if [[ "$count" == "__ERR__" ]]
  then
    echo "Couldn't check policies for user $user (no permission)." >> "$report"
    audit_failed="true"
    return
  fi

  if [[ "$count" -gt 0 ]] 
  then
    echo "User $user has the $ADMIN_POLICY_NAME policy." >> "$report"
    findings+=("user:$user")
    ((findings_count++))
  fi
}

check_role() {
  local role="$1"

  if [[ "$role" == AWSServiceRole* || "$role" == AWSServiceRoleFor* ]]
  then
   return
  fi

  local count
  count=$(aws iam list-attached-role-policies \
            --role-name "$role" \
            --query "length(AttachedPolicies[?PolicyName=='${ADMIN_POLICY_NAME}'])" \
            --output text 2>/dev/null || echo "__ERR__")

  if [[ "$count" == "__ERR__" ]]
  then
    echo "Couldn't check policies for role $role (no permission)." >> "$report"
    audit_failed="true"
    return
  fi

  if [[ "$count" -gt 0 ]]
  then
    echo "Role $role has the $ADMIN_POLICY_NAME policy." >> "$report"
    findings+=("role:$role")
    ((findings_count++))
  fi
}

check_group() {
  local group="$1"
  local count
  count=$(aws iam list-attached-group-policies \
            --group-name "$group" \
            --query "length(AttachedPolicies[?PolicyName=='${ADMIN_POLICY_NAME}'])" \
            --output text 2>/dev/null || echo "__ERR__")

  if [[ "$count" == "__ERR__" ]]
  then
    echo "Couldn't check policies for group $group (no permission)." >> "$report"
    audit_failed="true"
    return
  fi

  if [[ "$count" -gt 0 ]]
  then
    echo "Group $group has the $ADMIN_POLICY_NAME policy." >> "$report"
    findings+=("group:$group")
    ((findings_count++))
  fi
}

# List IAM users, roles and groups and check each one
printf "\nUsers with %s:\n" "$ADMIN_POLICY_NAME" >> "$report"
users=$(aws iam list-users --query "Users[].UserName" --output text 2>/dev/null)
if [[ $? -ne 0 ]]
then
  echo "Couldn't list users (missing permission)." >> "$report"
  audit_failed="true"
  users=""
fi

for u in $users
do
  [[ -n "$u" ]] && check_user "$u"
done

printf "\nRoles with %s:\n" "$ADMIN_POLICY_NAME" >> "$report"
roles=$(aws iam list-roles --query "Roles[].RoleName" --output text 2>/dev/null)

if [[ $? -ne 0 ]]
then
  echo "Couldn't list roles (missing permission)." >> "$report"
  audit_failed="true"
  roles=""
fi

for r in $roles;
do
  [[ -n "$r" ]] && check_role "$r"
done

printf "\nGroups with %s:\n" "$ADMIN_POLICY_NAME" >> "$report"
groups=$(aws iam list-groups --query "Groups[].GroupName" --output text 2>/dev/null)

if [[ $? -ne 0 ]]
then
  echo "Couldn't list groups (missing permission)." >> "$report"
  audit_failed="true"
  groups=""

fi
for g in $groups
do
  [[ -n "$g" ]] && check_group "$g"
done

{
  echo "----------------------------------"
  if [[ $findings_count -eq 0 ]]
  then
    printf "\nSummary: No users, roles, or groups with %s found.\n" "$ADMIN_POLICY_NAME"
  else
    printf "\nSummary: Found %d identities using %s.\n" "$findings_count" "$ADMIN_POLICY_NAME"
    printf "\nFindings:\n"
    for f in "${findings[@]}"
    do
      printf "  - %s\n" "$f"
    done
    alert_needed="true"
  fi
} >> "$report"

# Stop here if the audit hit permission errors
if [[ "$audit_failed" == "true" ]]
then
  printf "\nAudit couldn't finish cleanly because of permission issues.\n" >> "$report"
  echo "Some IAM checks failed (likely permissions). Have a look in $report."
  exit 2
fi

# Report uploads to S3
aws s3 cp "$report" "s3://$BUCKET/" >/dev/null
echo "Report uploaded to s3://$BUCKET/$report"

# SNS alert sends to subscribed email
if [[ "$alert_needed" == "true" ]]
then
  msg="IAM audit: found $findings_count identities with $ADMIN_POLICY_NAME. Report: s3://$BUCKET/$report"
  aws sns publish --topic-arn "$SNS_TOPIC_ARN" --message "$msg" \
                  --subject "IAM audit alert ($findings_count found)" >/dev/null
  echo "Alert sent to SNS topic."
else
  echo "No admin-level identities found, so no alert."
fi

echo "Audit is complete"
exit 0
