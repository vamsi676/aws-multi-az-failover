#!/bin/bash
# Minimal bootstrap: runtime + nginx + CodeDeploy agent. NO app code here;
# the app only arrives through CodeDeploy.
# Rendered by Terraform templatefile(): write a literal bash brace-variable as $${VAR}.
set -euxo pipefail

dnf install -y python3.11 nginx ruby

# Official CodeDeploy agent installer from the regional bucket.
curl -fsSL --retry 5 -o /tmp/codedeploy-install \
  "https://aws-codedeploy-${region}.s3.${region}.amazonaws.com/latest/install"
chmod +x /tmp/codedeploy-install
/tmp/codedeploy-install auto
rm -f /tmp/codedeploy-install

systemctl enable --now nginx
systemctl enable --now codedeploy-agent
