#!/usr/bin/env bash
# Manual failback: start the failback state machine (standby AZ -> primary AZ) and wait.
#
# Usage: AWS_PROFILE=<profile> scripts/start_failback.sh [--no-wait]
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
OUT="$(terraform -chdir="${ROOT_DIR}/envs/dev" output -json)"
tf_out() { jq -r --arg k "$1" '.[$k].value // empty' <<<"$OUT"; }
export AWS_REGION="$(tf_out aws_region)" AWS_PAGER=""
SM_ARN="$(tf_out failback_state_machine_arn)"

EXEC_ARN="$(aws stepfunctions start-execution \
  --state-machine-arn "$SM_ARN" \
  --name "failback-$(date -u +%Y%m%dT%H%M%SZ)" \
  --input '{}' \
  --query executionArn --output text)"
echo "Started ${EXEC_ARN##*:}"

[[ "${1:-}" == "--no-wait" ]] && exit 0

while true; do
  STATUS="$(aws stepfunctions describe-execution --execution-arn "$EXEC_ARN" --query status --output text)"
  [[ "$STATUS" != "RUNNING" ]] && break
  STATE="$(aws stepfunctions get-execution-history --execution-arn "$EXEC_ARN" --reverse-order \
    --max-items 20 --query 'events[?stateEnteredEventDetails] | [0].stateEnteredEventDetails.name' \
    --output text | head -1)"
  echo "$(date -u +%T) RUNNING (${STATE})"
  sleep 15
done

aws stepfunctions get-execution-history --execution-arn "$EXEC_ARN" \
  --query 'events[?stateEnteredEventDetails].[timestamp, stateEnteredEventDetails.name]' --output text
echo "Result: ${STATUS}"
[[ "$STATUS" == "SUCCEEDED" ]]
