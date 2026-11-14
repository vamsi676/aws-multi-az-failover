#!/usr/bin/env bash
# CI failure analyzer (runs in the ai-analyze job only when an earlier job failed).
# Takes the tail of each failed step's log, masks anything sensitive, asks Bedrock
# "what failed / likely cause / how to fix" and posts it as a PR comment
# (job summary for non-PR runs). Never changes the pipeline result.
#
# Usage: scripts/ci_ai_analyze.sh <dir-with-downloaded-ci-logs>
# Env:   BEDROCK_MODEL_ID, AWS creds, GH_TOKEN, PR_NUMBER (optional), GITHUB_STEP_SUMMARY
set -euo pipefail

LOG_ROOT="${1:?usage: ci_ai_analyze.sh <logs-dir>}"
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
MODEL_ID="${BEDROCK_MODEL_ID:?BEDROCK_MODEL_ID is not set}"
WORK="$(mktemp -d)"
MAX_LINES=200

# Mask account IDs, AWS keys, GitHub tokens, private keys, emails and IPv4 addresses.
mask() {
  sed -E \
    -e 's/(AKIA|ASIA)[A-Z0-9]{16}/<SECRET>/g' \
    -e 's/gh[pousr]_[A-Za-z0-9]{20,}/<SECRET>/g' \
    -e 's/github_pat_[A-Za-z0-9_]{20,}/<SECRET>/g' \
    -e 's/(aws_secret_access_key|aws_session_token|password|secret|token)([=: ]+)[^ ]+/\1\2<SECRET>/Ig' \
    -e '/-----BEGIN [A-Z ]*PRIVATE KEY-----/,/-----END [A-Z ]*PRIVATE KEY-----/c\<SECRET>' \
    -e 's/[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}/<EMAIL>/g' \
    -e 's/\b[0-9]{12}\b/<ACCOUNT_ID>/g' \
    -e 's/\b([0-9]{1,3}\.){3}[0-9]{1,3}(\/[0-9]{1,2})?\b/<IP>/g'
}

# Each failed job uploaded logs/<step>.log plus FAILED_STEP (path of its last-written log).
: > "$WORK/excerpt.txt"
while IFS= read -r marker; do
  job_dir="$(dirname "$marker")"
  job="$(basename "$job_dir")"
  step_log="$job_dir/$(basename "$(cat "$marker")")"
  [[ -f "$step_log" ]] || continue
  {
    echo "===== job: ${job#ci-logs-} | step log: $(basename "$step_log") (last ${MAX_LINES} lines) ====="
    tail -n "$MAX_LINES" "$step_log"
    echo
  } >> "$WORK/excerpt.txt"
done < <(find "$LOG_ROOT" -name FAILED_STEP | sort)

if [[ ! -s "$WORK/excerpt.txt" ]]; then
  echo "No FAILED_STEP markers found; nothing to analyze."
  exit 0
fi

mask < "$WORK/excerpt.txt" | tail -c 24000 > "$WORK/masked.txt"

jq -n --rawfile s "${ROOT_DIR}/prompts/ci_failure_analysis.txt" '[{text: $s}]' > "$WORK/system.json"
jq -n --rawfile l "$WORK/masked.txt" \
  '[{role: "user", content: [{text: ("Failed CI logs (masked):\n\n" + $l)}]}]' > "$WORK/messages.json"

if ! aws bedrock-runtime converse \
    --model-id "$MODEL_ID" \
    --system "file://$WORK/system.json" \
    --messages "file://$WORK/messages.json" \
    --inference-config maxTokens=600,temperature=0.2 \
    --output json > "$WORK/response.json" 2> "$WORK/error.txt"; then
  echo "::warning::Bedrock call failed: $(head -c 300 "$WORK/error.txt")"
  {
    echo "### AI failure analysis unavailable"
    echo "Bedrock call failed (model \`${MODEL_ID}\`). The CI result is unchanged; read the job logs."
  } >> "${GITHUB_STEP_SUMMARY:-/dev/stdout}"
  exit 1
fi

{
  echo "## 🤖 AI analysis of the failed CI run"
  echo
  jq -r '.output.message.content[0].text' "$WORK/response.json"
  echo
  echo "---"
  echo "<sub>Amazon Bedrock \`${MODEL_ID}\` on masked logs of run ${GITHUB_RUN_ID:-local}. Suggestions only; verify before applying.</sub>"
} > "$WORK/comment.md"

if [[ -n "${PR_NUMBER:-}" ]]; then
  gh pr comment "$PR_NUMBER" --body-file "$WORK/comment.md"
else
  cat "$WORK/comment.md" >> "${GITHUB_STEP_SUMMARY:-/dev/stdout}"
fi
echo "Posted AI analysis."
