#!/bin/bash
# AfterInstall: install the systemd unit and the nginx config from the bundle.
set -euo pipefail

APP_DIR=/opt/taskboard
ENV_FILE=/etc/taskboard/taskboard.env

# Written by the launch template user_data (table name + region).
if [[ ! -s "$ENV_FILE" ]]; then
  echo "Missing $ENV_FILE (written by user_data). Was this instance launched from an old launch template?" >&2
  exit 1
fi

chown -R root:root "$APP_DIR"
chmod -R a+rX "$APP_DIR"

install -m 0644 "$APP_DIR/config/taskboard.service" /etc/systemd/system/taskboard.service
install -m 0644 "$APP_DIR/config/nginx.conf" /etc/nginx/nginx.conf
nginx -t

systemctl daemon-reload
