#!/usr/bin/env bash
# Simulate an outage: stop the taskboard service on the active instance via SSM Run Command.
# The instance keeps running (ASG health check type EC2 does not replace it), so the NLB
# target goes unhealthy -> alarm -> (Phase 5+) automatic failover.
#
# Usage: AWS_PROFILE=<profile> scripts/simulate_outage.sh [--restore] [asg-name]
#   default ASG: ASG-a (the active AZ). --restore starts the service again.
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

ACTION="stop"
if [[ "${1:-}" == "--restore" ]]; then
  ACTION="start"
  shift
fi

OUT="$(terraform -chdir="${ROOT_DIR}/envs/dev" output -json)"
tf_out() { jq -r --arg k "$1" '.[$k].value // empty' <<<"$OUT"; }
export AWS_REGION="$(tf_out aws_region)" AWS_PAGER=""
ASG="${1:-$(tf_out asg_a_name)}"

INSTANCE_ID="$(aws autoscaling describe-auto-scaling-groups --auto-scaling-group-names "$ASG" \
  --query 'AutoScalingGroups[0].Instances[?LifecycleState==`InService`].InstanceId | [0]' \
  --output text)"
if [[ -z "$INSTANCE_ID" || "$INSTANCE_ID" == "None" ]]; then
  echo "No InService instance in ${ASG}." >&2
  exit 1
fi

echo "$(date -u +%FT%TZ) ${ACTION} taskboard on ${INSTANCE_ID} (${ASG})"
COMMAND_ID="$(aws ssm send-command \
  --instance-ids "$INSTANCE_ID" \
  --document-name AWS-RunShellScript \
  --comment "simulate_outage: ${ACTION} taskboard" \
  --parameters "commands=[\"systemctl ${ACTION} taskboard.service\",\"systemctl is-active taskboard.service || true\"]" \
  --query Command.CommandId --output text)"

aws ssm wait command-executed --command-id "$COMMAND_ID" --instance-id "$INSTANCE_ID" || true
aws ssm get-command-invocation --command-id "$COMMAND_ID" --instance-id "$INSTANCE_ID" \
  --query '[Status, StandardOutputContent]' --output text

if [[ "$ACTION" == "stop" ]]; then
  echo "Outage started. Expect: target unhealthy in ~20s, alarm ALARM in ~2-3 min."
  echo "Watch: scripts/status.sh   |   restore: scripts/simulate_outage.sh --restore ${ASG}"
fi
