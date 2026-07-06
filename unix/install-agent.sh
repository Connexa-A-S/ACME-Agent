#!/usr/bin/env bash
#
# Installs the CNXA ACME Unix fetch agent and a systemd timer (or prints a cron line).
#
set -eu

API_BASE_URL=""
SERVICE_API_KEY=""
OUTPUT_FORMAT="pem"
PFX_PASSWORD=""
INTERVAL_HOURS="12"

usage() {
    cat <<'USAGE'
Usage: install-agent.sh --api-base-url URL --service-api-key KEY [options]
  --api-base-url URL       e.g. https://acme.cnxa.cloud/api
  --service-api-key KEY    cnxa_svc_...
  --output-format pem|pfx  default: pem
  --pfx-password PASS      required when --output-format pfx
  --interval-hours N       default: 12
USAGE
    exit 1
}

while [ $# -gt 0 ]; do
    case "$1" in
        --api-base-url) API_BASE_URL="$2"; shift 2 ;;
        --service-api-key) SERVICE_API_KEY="$2"; shift 2 ;;
        --output-format) OUTPUT_FORMAT="$2"; shift 2 ;;
        --pfx-password) PFX_PASSWORD="$2"; shift 2 ;;
        --interval-hours) INTERVAL_HOURS="$2"; shift 2 ;;
        -h|--help) usage ;;
        *) echo "Unknown option: $1" >&2; usage ;;
    esac
done

[ "$(id -u)" = "0" ] || { echo "Run as root (installs to /etc, /usr/local/sbin, systemd)." >&2; exit 1; }
[ -n "$API_BASE_URL" ] || usage
[ -n "$SERVICE_API_KEY" ] || usage
if [ "$OUTPUT_FORMAT" = "pfx" ] && [ -z "$PFX_PASSWORD" ]; then
    echo "--pfx-password is required when --output-format is pfx" >&2; exit 1
fi

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
CONF_DIR="/etc/cnxa-acme"
HOOKS_DIR="$CONF_DIR/hooks.d"
DATA_DIR="/var/lib/cnxa-acme"
LOG_DIR="/var/log/cnxa-acme"
BIN="/usr/local/sbin/cnxa-acme-fetch"
CONFIG="$CONF_DIR/config.conf"

install -d -m 0755 "$CONF_DIR" "$HOOKS_DIR" "$LOG_DIR"
install -d -m 0750 "$DATA_DIR"
install -m 0755 "$SCRIPT_DIR/cnxa-acme-fetch.sh" "$BIN"

# Config holds the API key / PFX password; restrict to root.
umask 077
cat >"$CONFIG" <<EOF
API_BASE_URL=$API_BASE_URL
SERVICE_API_KEY=$SERVICE_API_KEY
OUTPUT_FORMAT=$OUTPUT_FORMAT
PFX_PASSWORD=$PFX_PASSWORD
OUTPUT_PATH=$DATA_DIR/certs
STATE_PATH=$DATA_DIR/state
LOG_PATH=$LOG_DIR
HOOKS_PATH=$HOOKS_DIR
RUN_HOOKS_ON_FIRST_DOWNLOAD=true
EOF
chmod 600 "$CONFIG"
umask 022

# Ship the example hook if the hooks dir is empty.
if [ -z "$(ls -A "$HOOKS_DIR" 2>/dev/null)" ] && [ -d "$SCRIPT_DIR/hooks.d" ]; then
    cp "$SCRIPT_DIR/hooks.d/"*.sh "$HOOKS_DIR/" 2>/dev/null || true
fi

if command -v systemctl >/dev/null 2>&1; then
    cat >/etc/systemd/system/cnxa-acme-agent.service <<EOF
[Unit]
Description=CNXA ACME fetch agent
After=network-online.target
Wants=network-online.target

[Service]
Type=oneshot
ExecStart=$BIN $CONFIG
EOF

    cat >/etc/systemd/system/cnxa-acme-agent.timer <<EOF
[Unit]
Description=Run CNXA ACME fetch agent every $INTERVAL_HOURS h

[Timer]
OnBootSec=5min
OnUnitActiveSec=${INTERVAL_HOURS}h
Persistent=true

[Install]
WantedBy=timers.target
EOF

    systemctl daemon-reload
    systemctl enable --now cnxa-acme-agent.timer
    echo "Installed. Timer active. Run now with: systemctl start cnxa-acme-agent.service"
    echo "Logs: journalctl -u cnxa-acme-agent.service  or  $LOG_DIR/"
else
    echo "Installed (no systemd found). Add a cron entry, e.g.:"
    echo "  0 */$INTERVAL_HOURS * * * root $BIN $CONFIG >/dev/null 2>&1"
fi
