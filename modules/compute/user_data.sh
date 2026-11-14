#!/bin/bash
# Minimal bootstrap: runtime + nginx + CodeDeploy agent. NO app code here;
# the app only arrives through CodeDeploy.
# Rendered by Terraform templatefile(): write a literal bash brace-variable as $${VAR}.
set -euxo pipefail

dnf install -y python3.11 nginx ruby

# App runtime settings (read by the taskboard systemd unit via EnvironmentFile).
mkdir -p /etc/taskboard
cat > /etc/taskboard/taskboard.env <<EOF
TABLE_NAME=${table_name}
AWS_REGION=${region}
AWS_DEFAULT_REGION=${region}
EOF
chmod 0644 /etc/taskboard/taskboard.env

# Official CodeDeploy agent installer from the regional bucket.
curl -fsSL --retry 5 -o /tmp/codedeploy-install \
  "https://aws-codedeploy-${region}.s3.${region}.amazonaws.com/latest/install"
chmod +x /tmp/codedeploy-install
/tmp/codedeploy-install auto
rm -f /tmp/codedeploy-install

systemctl enable --now nginx
systemctl enable --now codedeploy-agent
