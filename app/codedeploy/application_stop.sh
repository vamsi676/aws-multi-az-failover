#!/bin/bash
# ApplicationStop: stop the running app. On a fresh instance the unit does not
# exist yet, which is fine.
set -euo pipefail

systemctl stop taskboard.service 2>/dev/null || true
echo "taskboard stopped (or was not installed)"
