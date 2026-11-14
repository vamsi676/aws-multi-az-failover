#!/bin/bash
# ValidateService: /healthz through nginx must return 200 within ~60s.
# A failure here fails the deployment and triggers automatic rollback.
set -uo pipefail

for attempt in $(seq 1 30); do
  if curl -fsS -m 2 http://127.0.0.1/healthz; then
    echo
    echo "healthy after ${attempt} attempt(s)"
    exit 0
  fi
  sleep 2
done

echo "taskboard did not become healthy within 60s" >&2
systemctl status taskboard.service --no-pager >&2 || true
journalctl -u taskboard.service -n 50 --no-pager >&2 || true
exit 1
