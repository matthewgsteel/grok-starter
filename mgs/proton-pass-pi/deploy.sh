#!/usr/bin/env bash
set -euo pipefail

BASE=/home/mgs/mcp-services/proton-pass-pi
RAW=https://raw.githubusercontent.com/matthewgsteel/grok-starter/main/mgs/proton-pass-pi

mkdir -p "$BASE"

curl -fsSL "$RAW/server.mjs" -o "$BASE/server.mjs"
curl -fsSL "$RAW/proxy.mjs" -o "$BASE/proxy.mjs"
ln -sfn /home/mgs/mcp-services/proton-drive/node_modules "$BASE/node_modules"

/usr/bin/node --check "$BASE/server.mjs"
/usr/bin/node --check "$BASE/proxy.mjs"

curl -fsSL "$RAW/mgs-proton-pass-mcp.service" -o /tmp/mgs-proton-pass-mcp.service
curl -fsSL "$RAW/mgs-proton-pass-proxy.service" -o /tmp/mgs-proton-pass-proxy.service

sudo -n install -m 0644 /tmp/mgs-proton-pass-mcp.service /etc/systemd/system/mgs-proton-pass-mcp.service
sudo -n install -m 0644 /tmp/mgs-proton-pass-proxy.service /etc/systemd/system/mgs-proton-pass-proxy.service
sudo -n systemctl daemon-reload
sudo -n systemctl enable --now mgs-proton-pass-mcp.service mgs-proton-pass-proxy.service

sleep 4
systemctl is-active mgs-proton-pass-mcp.service
systemctl is-active mgs-proton-pass-proxy.service
sudo -n ss -lntp | grep -E ':(8012|8013)\b'

cat <<'EOF'
PASS_DEPLOY_OK
Pi-native Proton Pass MCP: 127.0.0.1:8012/mcp
Path rewrite proxy:       127.0.0.1:8013/<existing connector path>
EOF
