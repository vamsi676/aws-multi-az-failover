#!/usr/bin/env bash
# Upload a bundle to S3 (releases/<version>.zip), start a CodeDeploy deployment and wait.
#
# Usage: scripts/deploy_app.sh dist/taskboard-<version>.zip
# Names come from `terraform output` in envs/dev, or from the environment
# (ARTIFACTS_BUCKET, CODEDEPLOY_APP, CODEDEPLOY_GROUP, AWS_REGION), e.g. in CI.
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ZIP="${1:?usage: deploy_app.sh <bundle.zip>}"
[[ -f "$ZIP" ]] || { echo "No such file: $ZIP" >&2; exit 1; }

if [[ -z "${ARTIFACTS_BUCKET:-}" || -z "${CODEDEPLOY_APP:-}" || -z "${CODEDEPLOY_GROUP:-}" ]]; then
  OUT="$(terraform -chdir="${ROOT_DIR}/envs/dev" output -json)"
  tf_out() { jq -r --arg k "$1" '.[$k].value // empty' <<<"$OUT"; }
  ARTIFACTS_BUCKET="${ARTIFACTS_BUCKET:-$(tf_out artifacts_bucket_name)}"
  CODEDEPLOY_APP="${CODEDEPLOY_APP:-$(tf_out codedeploy_app_name)}"
  CODEDEPLOY_GROUP="${CODEDEPLOY_GROUP:-$(tf_out codedeploy_deployment_group_name)}"
  AWS_REGION="${AWS_REGION:-$(tf_out aws_region)}"
fi
export AWS_REGION="${AWS_REGION:-us-east-1}" AWS_PAGER=""

VERSION="$(basename "$ZIP" .zip)"
VERSION="${VERSION#taskboard-}"
KEY="releases/${VERSION}.zip"

echo "Uploading ${ZIP} -> s3://${ARTIFACTS_BUCKET}/${KEY}"
aws s3 cp "$ZIP" "s3://${ARTIFACTS_BUCKET}/${KEY}" --only-show-errors

DEPLOYMENT_ID="$(aws deploy create-deployment \
  --application-name "$CODEDEPLOY_APP" \
  --deployment-group-name "$CODEDEPLOY_GROUP" \
  --s3-location "bucket=${ARTIFACTS_BUCKET},key=${KEY},bundleType=zip" \
  --description "Taskboard ${VERSION}" \
  --query deploymentId --output text)"
echo "Deployment ${DEPLOYMENT_ID} started; waiting..."

if aws deploy wait deployment-successful --deployment-id "$DEPLOYMENT_ID"; then
  echo "Deployment ${DEPLOYMENT_ID} Succeeded (version ${VERSION})"
  exit 0
fi

echo "Deployment ${DEPLOYMENT_ID} did not succeed:" >&2
aws deploy get-deployment --deployment-id "$DEPLOYMENT_ID" \
  --query 'deploymentInfo.{status:status,error:errorInformation,rollback:rollbackInfo}' --output json >&2
for iid in $(aws deploy list-deployment-targets --deployment-id "$DEPLOYMENT_ID" \
    --query 'targetIds[]' --output text); do
  aws deploy get-deployment-target --deployment-id "$DEPLOYMENT_ID" --target-id "$iid" \
    --query 'deploymentTarget.instanceTarget.lifecycleEvents[?status!=`Succeeded`].[lifecycleEventName,status,diagnostics.message,diagnostics.logTail]' \
    --output text >&2 || true
done
exit 1
