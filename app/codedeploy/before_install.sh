#!/bin/bash
# BeforeInstall: service user + clean install directory.
set -euo pipefail

if ! id -u taskboard >/dev/null 2>&1; then
  useradd --system --no-create-home --shell /sbin/nologin taskboard
fi

# Start from an empty directory so files removed from a release do not linger.
rm -rf /opt/taskboard
mkdir -p /opt/taskboard
