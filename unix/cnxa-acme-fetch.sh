#!/usr/bin/env bash
#
# CNXA ACME fetch agent (Unix).
#
# Checks the CNXA ACME Platform for the assigned service certificate. If the remote
# fingerprint has changed, downloads the new certificate to a versioned local folder,
# updates current/, saves state, and runs hook scripts in hooks.d/.
#
# Dependencies: bash, curl, sed, grep. PEM output also needs unzip.
# Deliberately deployment-neutral: product-specific actions belong in hooks.
#
set -eu

CONFIG="${CNXA_CONFIG:-${1:-/etc/cnxa-acme/config.conf}}"
FORCE="${CNXA_FORCE:-0}"

LOG_FILE=""
log() {
    line="$(date -u +%Y-%m-%dT%H:%M:%SZ) [${2:-INFO}] $1"
    printf '%s\n' "$line"
    [ -n "$LOG_FILE" ] && printf '%s\n' "$line" >>"$LOG_FILE" 2>/dev/null || true
}
die() { log "$1" ERROR; exit "${2:-1}"; }

[ -f "$CONFIG" ] || die "Config not found: $CONFIG"

# Read KEY=VALUE from the config without executing it (config is trusted/root-owned,
# but parsing avoids surprises from stray shell in values).
conf_get() {
    grep -E "^[[:space:]]*$1=" "$CONFIG" 2>/dev/null | head -n1 \
        | sed -E "s/^[[:space:]]*$1=//" | sed -E 's/^"(.*)"$/\1/; s/^'\''(.*)'\''$/\1/'
}

# Extract a JSON string value: "key":"value"  (flat fields only).
json_str() {
    printf '%s' "$1" | grep -o "\"$2\"[[:space:]]*:[[:space:]]*\"[^\"]*\"" | head -n1 \
        | sed -E 's/.*:[[:space:]]*"(.*)"$/\1/'
}
# Extract a JSON number value: "key":123
json_num() {
    printf '%s' "$1" | grep -o "\"$2\"[[:space:]]*:[[:space:]]*[0-9]\+" | head -n1 \
        | sed -E 's/.*:[[:space:]]*([0-9]+)$/\1/'
}

API_BASE_URL="$(conf_get API_BASE_URL)"
SERVICE_API_KEY="$(conf_get SERVICE_API_KEY)"
OUTPUT_FORMAT="$(printf '%s' "$(conf_get OUTPUT_FORMAT)" | tr 'A-Z' 'a-z')"
[ -n "$OUTPUT_FORMAT" ] || OUTPUT_FORMAT="pem"
PFX_PASSWORD="$(conf_get PFX_PASSWORD)"
OUTPUT_PATH="$(conf_get OUTPUT_PATH)"; [ -n "$OUTPUT_PATH" ] || OUTPUT_PATH="/var/lib/cnxa-acme/certs"
STATE_PATH="$(conf_get STATE_PATH)"; [ -n "$STATE_PATH" ] || STATE_PATH="/var/lib/cnxa-acme/state"
LOG_PATH="$(conf_get LOG_PATH)"; [ -n "$LOG_PATH" ] || LOG_PATH="/var/log/cnxa-acme"
HOOKS_PATH="$(conf_get HOOKS_PATH)"; [ -n "$HOOKS_PATH" ] || HOOKS_PATH="/etc/cnxa-acme/hooks.d"
RUN_HOOKS_ON_FIRST="$(conf_get RUN_HOOKS_ON_FIRST_DOWNLOAD)"; [ -n "$RUN_HOOKS_ON_FIRST" ] || RUN_HOOKS_ON_FIRST="true"

[ -n "$API_BASE_URL" ] || die "API_BASE_URL is missing in config"
[ -n "$SERVICE_API_KEY" ] || die "SERVICE_API_KEY is missing in config"
case "$OUTPUT_FORMAT" in pem|pfx) ;; *) die "OUTPUT_FORMAT must be pem or pfx" ;; esac

mkdir -p "$OUTPUT_PATH" "$LOG_PATH" "$(dirname "$STATE_PATH")"
LOG_FILE="$LOG_PATH/agent-$(date -u +%Y%m%d).log"

api_base="${API_BASE_URL%/}"

log "Checking ACME service at $api_base"
info="$(curl -fsS -H "X-API-Key: $SERVICE_API_KEY" -H "User-Agent: CNXA-ACME-Unix-Agent/1.0" "$api_base/agent/info")" \
    || die "agent/info request failed"

status="$(json_str "$info" status)"
if [ "$status" != "active" ]; then
    log "Service is not active (status=$status)" WARN
    exit 0
fi

fingerprint="$(json_str "$info" fingerprint)"
[ -n "$fingerprint" ] || { log "Remote did not return a fingerprint" WARN; exit 0; }

service_name="$(json_str "$info" service_name)"
[ -n "$service_name" ] || service_name="service-$(json_num "$info" service_id)"
service_id="$(json_num "$info" service_id)"
customer_number="$(json_str "$info" customer_number)"
domain="$(json_str "$info" domain)"
pem_url="$(json_str "$info" download_pem_url)"
pfx_url="$(json_str "$info" download_pfx_url)"

state_get() { [ -f "$STATE_PATH" ] && grep -E "^$1=" "$STATE_PATH" | head -n1 | sed -E "s/^$1=//" || true; }
prev_fingerprint="$(state_get fingerprint)"

service_root="$OUTPUT_PATH/$service_name"
current_dir="$service_root/current"

current_valid() {
    if [ "$OUTPUT_FORMAT" = "pfx" ]; then
        [ -s "$current_dir/certificate.pfx" ]
    else
        [ -s "$current_dir/cert.crt" ] && [ -s "$current_dir/cert.key" ]
    fi
}

changed=0
[ "$FORCE" = "1" ] && changed=1
[ "$fingerprint" != "$prev_fingerprint" ] && changed=1

if [ "$changed" = "0" ]; then
    if current_valid; then
        log "Certificate unchanged. Fingerprint: $fingerprint"
        exit 0
    fi
    log "Unchanged, but current/ is missing/incomplete. Forcing download." WARN
    changed=1
fi

first_download=0
[ -z "$prev_fingerprint" ] && first_download=1
log "Certificate update detected. Previous='$prev_fingerprint' New='$fingerprint'"

version_label="fetched-$(date -u +%Y%m%d-%H%M%S)"
version_dir="$service_root/versions/$version_label"
tmp_dir="$service_root/tmp-download"
mkdir -p "$version_dir"
rm -rf "$tmp_dir"; mkdir -p "$tmp_dir"
trap 'rm -rf "$tmp_dir"' EXIT

if [ "$OUTPUT_FORMAT" = "pfx" ]; then
    [ -n "$PFX_PASSWORD" ] || die "PFX_PASSWORD is required when OUTPUT_FORMAT is pfx"
    out="$tmp_dir/certificate.pfx"
    curl -fsS -X POST -H "X-API-Key: $SERVICE_API_KEY" -H "Content-Type: application/json" \
        -d "{\"password\":\"$PFX_PASSWORD\"}" -o "$out" "$api_base$pfx_url" || die "PFX download failed"
    [ -s "$out" ] || die "Downloaded PFX is missing or empty"
    cp "$out" "$version_dir/certificate.pfx"
else
    command -v unzip >/dev/null 2>&1 || die "unzip is required for PEM output"
    zip="$tmp_dir/cert.zip"
    curl -fsS -H "X-API-Key: $SERVICE_API_KEY" -o "$zip" "$api_base$pem_url" || die "PEM download failed"
    [ -s "$zip" ] || die "Downloaded PEM zip is missing or empty"
    unzip -o -q "$zip" -d "$version_dir" || die "Failed to extract PEM zip"
fi

{
    printf 'service_id=%s\n' "$service_id"
    printf 'service_name=%s\n' "$service_name"
    printf 'domain=%s\n' "$domain"
    printf 'fingerprint=%s\n' "$fingerprint"
    printf 'version_label=%s\n' "$version_label"
    printf 'fetched_at=%s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
} >"$version_dir/metadata.txt"

rm -rf "$current_dir"; mkdir -p "$current_dir"
cp -a "$version_dir/." "$current_dir/"
current_valid || die "current/ is incomplete after copy"

{
    printf 'fingerprint=%s\n' "$fingerprint"
    printf 'version_label=%s\n' "$version_label"
    printf 'current_path=%s\n' "$current_dir"
    printf 'last_checked_at=%s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
} >"$STATE_PATH"

log "Certificate saved to $current_dir"

# ---- hooks ------------------------------------------------------------------
run_hooks=1
[ "$first_download" = "1" ] && [ "$RUN_HOOKS_ON_FIRST" != "true" ] && run_hooks=0

if [ "$run_hooks" = "1" ] && [ -d "$HOOKS_PATH" ]; then
    export CNXA_CURRENT_PATH="$current_dir"
    export CNXA_VERSION_PATH="$version_dir"
    export CNXA_FORMAT="$OUTPUT_FORMAT"
    export CNXA_SERVICE_ID="$service_id"
    export CNXA_SERVICE_NAME="$service_name"
    export CNXA_CUSTOMER_NUMBER="$customer_number"
    export CNXA_DOMAIN="$domain"
    export CNXA_FINGERPRINT="$fingerprint"
    export CNXA_PREVIOUS_FINGERPRINT="$prev_fingerprint"

    for name in $(ls -1 "$HOOKS_PATH" 2>/dev/null | sort); do
        hook="$HOOKS_PATH/$name"
        [ -f "$hook" ] || continue
        case "$name" in *.sh) ;; *) [ -x "$hook" ] || continue ;; esac
        hooklog="$LOG_PATH/hook-${name%.sh}-$(date -u +%Y%m%d).log"
        log "Running hook: $name"
        set +e
        if [ -x "$hook" ]; then "$hook" >>"$hooklog" 2>&1; else bash "$hook" >>"$hooklog" 2>&1; fi
        rc=$?
        set -e
        case "$rc" in
            0) log "Hook OK: $name" ;;
            1) log "Hook warning (rc=1): $name. See $hooklog" WARN ;;
            2) die "Hook requested retry (rc=2): $name. See $hooklog" 2 ;;
            *) die "Hook failed (rc=$rc): $name. See $hooklog" 3 ;;
        esac
    done
else
    log "No hooks run."
fi

log "Done"
