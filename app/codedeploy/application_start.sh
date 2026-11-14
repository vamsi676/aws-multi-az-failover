#!/bin/bash
# ApplicationStart: (re)start the app and pick up the nginx config.
set -euo pipefail

systemctl enable taskboard.service
systemctl restart taskboard.service

systemctl enable nginx.service
systemctl reload-or-restart nginx.service
