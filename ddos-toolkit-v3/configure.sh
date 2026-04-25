#!/usr/bin/env bash
# =============================================================================
# DDoS Toolkit v3 — interactive configuration
# =============================================================================
# Sets values in /etc/default/ddos-toolkit. Both the cron'd ddos-behavior-engine
# and a manual run of it source that file at startup, so changes here take
# effect on the next cron tick (max 60 s) — no daemon restart required.
#
# Usage:
#   sudo ./configure.sh                            interactive menu
#   sudo ./configure.sh --show                     print current config
#   sudo ./configure.sh --webhook <URL>            set ALERT_WEBHOOK_URL
#   sudo ./configure.sh --discord-webhook <URL>    same, more explicit name
#   sudo ./configure.sh --set KEY=VALUE            set any single key
#   sudo ./configure.sh --unset KEY                remove a key
#   sudo ./configure.sh --test                     fire a test alert through the
#                                                  configured webhook
#
# Configurable keys (each is documented in /etc/default/ddos-toolkit):
#   ALERT_WEBHOOK_URL       — Discord/Slack/generic JSON webhook for blocks
#   REQUESTS_THRESHOLD      — blocks IPs above N requests in WINDOW_SECONDS (default 100)
#   ERROR_THRESHOLD         — blocks IPs above N 4xx/5xx in WINDOW_SECONDS (default 30)
#   WINDOW_SECONDS          — observation window in seconds (default 60)
# =============================================================================
set -euo pipefail

RED=$'\033[0;31m'
GREEN=$'\033[0;32m'
YELLOW=$'\033[1;33m'
CYAN=$'\033[0;36m'
GRAY=$'\033[0;90m'
NC=$'\033[0m'

CONFIG_FILE="${DDOS_CONFIG:-/etc/default/ddos-toolkit}"

log()      { printf "%s[+]%s %s\n" "$GREEN"  "$NC" "$*"; }
warn()     { printf "%s[!]%s %s\n" "$YELLOW" "$NC" "$*"; }
err()      { printf "%s[✗]%s %s\n" "$RED"    "$NC" "$*" >&2; }
section()  { printf "\n%s═══ %s%s\n" "$CYAN" "$*" "$NC"; }
hint()     { printf "%s    %s%s\n" "$GRAY"   "$*" "$NC"; }

[[ $EUID -eq 0 ]] || { err "Run as root (sudo $0)"; exit 1; }

# ---------------------------------------------------------------------------
# Read current config — return empty string for missing keys
# ---------------------------------------------------------------------------
get_value() {
    local key="$1"
    [[ -f "$CONFIG_FILE" ]] || { echo ""; return; }
    grep -E "^${key}=" "$CONFIG_FILE" 2>/dev/null | tail -1 | cut -d= -f2- | sed -E 's/^"(.*)"$/\1/' || true
}

# Atomic upsert: replace the line if present, else append.
set_value() {
    local key="$1" val="$2"
    if [[ ! -f "$CONFIG_FILE" ]]; then
        cat > "$CONFIG_FILE" <<'EOF'
# DDoS Toolkit v3 — runtime configuration.
# Sourced by /usr/local/sbin/ddos-behavior-engine.sh on every run.
# Edit with `sudo configure.sh` or by hand. Restart cron is NOT required —
# the next cron tick (within 60 s) picks up any changes.

# --- Alerting ---------------------------------------------------------------
# When the engine blocks any IPs, it POSTs a JSON message to this webhook.
# Empty = no alerts. Both Discord webhook URLs and Slack incoming-webhook URLs
# work (the JSON body is generic enough for both).
ALERT_WEBHOOK_URL=""

# --- Detection thresholds ---------------------------------------------------
# All three feed the same observation window. Tune for your traffic profile.
WINDOW_SECONDS="60"
REQUESTS_THRESHOLD="100"
ERROR_THRESHOLD="30"
EOF
        chmod 0640 "$CONFIG_FILE"
        chown root:root "$CONFIG_FILE"
    fi
    # If the key already exists → replace; else → append.
    if grep -qE "^${key}=" "$CONFIG_FILE"; then
        # Use awk for safe replacement (sed escaping is hostile)
        local tmp; tmp=$(mktemp)
        awk -v k="$key" -v v="$val" '
            BEGIN { found=0 }
            $0 ~ "^"k"=" { print k "=\"" v "\""; found=1; next }
            { print }
        ' "$CONFIG_FILE" > "$tmp"
        mv "$tmp" "$CONFIG_FILE"
    else
        printf '%s="%s"\n' "$key" "$val" >> "$CONFIG_FILE"
    fi
    chmod 0640 "$CONFIG_FILE"
    chown root:root "$CONFIG_FILE"
}

unset_value() {
    [[ ! -f "$CONFIG_FILE" ]] && return
    local tmp; tmp=$(mktemp)
    grep -vE "^${1}=" "$CONFIG_FILE" > "$tmp" || true
    mv "$tmp" "$CONFIG_FILE"
    chmod 0640 "$CONFIG_FILE"
}

mask() {
    # Show only the last 12 chars of the URL (Discord webhook ID prefix)
    local s="$1"
    if [[ ${#s} -gt 24 ]]; then
        printf '%s...%s\n' "${s:0:32}" "${s: -8}"
    else
        printf '%s\n' "$s"
    fi
}

show_config() {
    section "Current configuration ($CONFIG_FILE)"
    if [[ ! -f "$CONFIG_FILE" ]]; then
        warn "config file not found — run with --webhook or --set to create it"
        return
    fi
    local url thr_req thr_err win
    url=$(get_value ALERT_WEBHOOK_URL)
    thr_req=$(get_value REQUESTS_THRESHOLD)
    thr_err=$(get_value ERROR_THRESHOLD)
    win=$(get_value WINDOW_SECONDS)
    printf '  %-22s %s\n' "ALERT_WEBHOOK_URL"  "$([ -n "$url"     ] && mask "$url" || echo '(unset)')"
    printf '  %-22s %s\n' "REQUESTS_THRESHOLD" "${thr_req:-(default 100)}"
    printf '  %-22s %s\n' "ERROR_THRESHOLD"    "${thr_err:-(default 30)}"
    printf '  %-22s %s\n' "WINDOW_SECONDS"     "${win:-(default 60)}"
}

validate_webhook() {
    local url="$1"
    [[ -z "$url" ]] && return 0   # empty = disable alerts, that's allowed
    if [[ ! "$url" =~ ^https:// ]]; then
        err "webhook must be HTTPS"
        return 1
    fi
    if [[ ! "$url" =~ (discord(app)?\.com|slack\.com|hooks\.slack\.com) ]] \
       && [[ ! "$url" =~ ^https://[a-z0-9.-]+\.[a-z]{2,}/ ]]; then
        warn "webhook host doesn't look like Discord/Slack — proceeding anyway"
    fi
    return 0
}

test_webhook() {
    local url
    url=$(get_value ALERT_WEBHOOK_URL)
    if [[ -z "$url" ]]; then
        err "ALERT_WEBHOOK_URL is empty. Set it first: sudo $0 --webhook <URL>"
        return 1
    fi
    section "Sending test alert"
    local payload
    payload=$(printf '{"content":"🛡️ DDoS toolkit test alert from %s @ %s"}' "$(hostname)" "$(date -Is)")
    local code
    code=$(curl -fsS --max-time 5 -X POST -H 'Content-Type: application/json' \
           -d "$payload" -o /dev/null -w '%{http_code}' "$url" || echo 000)
    if [[ "$code" =~ ^2 ]]; then
        log "webhook delivered (HTTP $code)"
    else
        err "webhook failed (HTTP $code) — check the URL"
        return 1
    fi
}

# ---------------------------------------------------------------------------
# CLI
# ---------------------------------------------------------------------------
if [[ $# -eq 0 ]]; then
    # Interactive
    show_config
    echo
    read -rp "$(printf '%s' 'New ALERT_WEBHOOK_URL (blank = keep, "-" = unset): ')" url
    case "$url" in
        '')   warn "kept" ;;
        '-')  unset_value ALERT_WEBHOOK_URL; log "unset" ;;
        *)
            validate_webhook "$url" || exit 1
            set_value ALERT_WEBHOOK_URL "$url"
            log "saved"
            ;;
    esac
    echo
    read -rp "$(printf '%s' 'REQUESTS_THRESHOLD (blank = keep): ')" rt
    [[ -n "$rt" ]] && set_value REQUESTS_THRESHOLD "$rt" && log "saved"
    read -rp "$(printf '%s' 'ERROR_THRESHOLD (blank = keep): ')"    et
    [[ -n "$et" ]] && set_value ERROR_THRESHOLD "$et" && log "saved"
    read -rp "$(printf '%s' 'WINDOW_SECONDS (blank = keep): ')"     ws
    [[ -n "$ws" ]] && set_value WINDOW_SECONDS "$ws" && log "saved"
    echo
    show_config
    hint "Changes apply on the next cron tick (≤ 60 s)."
    exit 0
fi

while [[ $# -gt 0 ]]; do
    case "$1" in
        --show)    show_config; shift ;;
        --webhook|--discord-webhook|--slack-webhook)
            validate_webhook "$2" || exit 1
            set_value ALERT_WEBHOOK_URL "$2"
            log "ALERT_WEBHOOK_URL saved"
            shift 2 ;;
        --set)
            [[ "$2" =~ = ]] || { err "expected KEY=VALUE, got: $2"; exit 1; }
            set_value "${2%%=*}" "${2#*=}"
            log "${2%%=*} saved"
            shift 2 ;;
        --unset)
            unset_value "$2"
            log "$2 removed"
            shift 2 ;;
        --test)
            test_webhook
            shift ;;
        -h|--help) sed -n '2,/^# ====/p' "$0"; exit 0 ;;
        *) err "unknown arg: $1"; exit 1 ;;
    esac
done
