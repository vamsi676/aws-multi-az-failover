#!/usr/bin/env bash
# Read-only status of the envs/dev stack: ASGs, target health, alarm,
# state machine executions and the latest CodeDeploy deployment.
#
# Usage: AWS_PROFILE=<profile> scripts/status.sh
# Note: with --max-items the CLI also prints a pagination token line ("None"), hence "| head -1".
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TF_DIR="${ROOT_DIR}/envs/dev"

for bin in aws jq terraform; do
  command -v "$bin" >/dev/null 2>&1 || { echo "Missing required tool: $bin" >&2; exit 1; }
done

OUT="$(terraform -chdir="$TF_DIR" output -json)"
if [[ "$OUT" == "{}" || -z "$OUT" ]]; then
  echo "No Terraform outputs found. Is envs/dev applied?" >&2
  exit 1
fi

tf_out() { jq -r --arg k "$1" '.[$k].value // empty' <<<"$OUT"; }

REGION="$(tf_out aws_region)"
PREFIX="$(tf_out name_prefix)"
ASG_A="$(tf_out asg_a_name)"
ASG_B="$(tf_out asg_b_name)"
TG_ARN="$(tf_out target_group_arn)"
CD_APP="$(tf_out codedeploy_app_name)"
CD_DG="$(tf_out codedeploy_deployment_group_name)"
APP_URL="$(tf_out app_url)"

export AWS_REGION="$REGION" AWS_PAGER=""

section() { printf '\n== %s ==\n' "$1"; }

section "App"
echo "$APP_URL"

section "Auto Scaling groups"
aws autoscaling describe-auto-scaling-groups \
  --auto-scaling-group-names "$ASG_A" "$ASG_B" \
  --query 'AutoScalingGroups[].{ASG:AutoScalingGroupName,AZ:AvailabilityZones[0],Desired:DesiredCapacity,InService:length(Instances[?LifecycleState==`InService`]),Instances:join(`,`, Instances[].InstanceId)}' \
  --output table

section "Target health"
targets="$(aws elbv2 describe-target-health --target-group-arn "$TG_ARN" \
  --query 'TargetHealthDescriptions[].[Target.Id,TargetHealth.State,TargetHealth.Reason]' \
  --output text)"
if [[ -z "$targets" ]]; then
  echo "(no targets registered)"
else
  echo "$targets" | column -t
fi

section "CloudWatch alarms"
alarms="$(aws cloudwatch describe-alarms --alarm-name-prefix "${PREFIX}-" \
  --query 'MetricAlarms[].[AlarmName,StateValue,StateUpdatedTimestamp]' --output text)"
if [[ -z "$alarms" ]]; then
  echo "(no alarms yet - created in Phase 4)"
else
  echo "$alarms" | column -t
fi

section "State machines (latest execution)"
machines="$(aws stepfunctions list-state-machines \
  --query "stateMachines[?starts_with(name, '${PREFIX}-')].stateMachineArn" --output text)"
if [[ -z "$machines" ]]; then
  echo "(no state machines yet - created in Phase 5)"
else
  for arn in $machines; do
    latest="$(aws stepfunctions list-executions --state-machine-arn "$arn" --max-items 1 \
      --query 'executions[0].[name,status,startDate]' --output text | head -1)"
    [[ -z "$latest" || "$latest" == "None" ]] && latest="(no executions)"
    printf '%s  %s\n' "${arn##*:}" "$latest"
  done
fi

section "Latest CodeDeploy deployment"
dep_id="$(aws deploy list-deployments --application-name "$CD_APP" \
  --deployment-group-name "$CD_DG" --max-items 1 \
  --query 'deployments[0]' --output text | head -1)"
if [[ -z "$dep_id" || "$dep_id" == "None" ]]; then
  echo "(no deployments yet - first one in Phase 2)"
else
  aws deploy get-deployment --deployment-id "$dep_id" \
    --query 'deploymentInfo.[deploymentId,status,createTime,revision.s3Location.key]' \
    --output text
fi
