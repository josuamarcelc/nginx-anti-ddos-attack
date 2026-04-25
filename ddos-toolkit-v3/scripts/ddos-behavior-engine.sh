#!/usr/bin/env bash
# =============================================================================
# Adaptive behavior-based blocker
# =============================================================================
# Static rate-limit rules are fixed. This script watches recent request
# behavior in the access log and writes an nginx blocklist for IPs whose
# pattern looks abusive — high request count, all-4xx, scanner-flavored
# UAs, etc. Re-runs every minute via cron.
#
# Behaviors flagged:
#   - >= REQUESTS_THRESHOLD requests in WINDOW_SECONDS
#   - >= ERROR_THRESHOLD 4xx/5xx responses (probably hitting random URLs)
#   - any single 444 response (already-flagged by ddos-advanced.conf)
#
# Whitelist: /etc/nginx/ddos-whitelist.conf is loaded first so "you" don't
# self-ban during legitimate maintenance/scraping.
#
# Output: /etc/nginx/ddos-blocklist-generated.conf  (deny <ip>; lines)
# Reload: nginx -s reload  (atomic; existing connections stay)
# =============================================================================
set -euo pipefail

# --- Tunables ----------------------------------------------------------------
LOG="${LOG:-/var/log/nginx/access.log}"
BLOCKLIST="${BLOCKLIST:-/etc/nginx/ddos-blocklist-generated.conf}"
WHITELIST="${WHITELIST:-/etc/nginx/ddos-whitelist.conf}"
META="${META:-/etc/nginx/ddos-blocklist-meta.json}"
STATE_LOG="${STATE_LOG:-/var/log/ddos-nginx-autoblock.log}"
WINDOW_SECONDS="${WINDOW_SECONDS:-60}"
REQUESTS_THRESHOLD="${REQUESTS_THRESHOLD:-100}"   # > N reqs in window → block
ERROR_THRESHOLD="${ERROR_THRESHOLD:-30}"          # > N 4xx/5xx in window → block
ALERT_WEBHOOK_URL="${ALERT_WEBHOOK_URL:-}"        # optional Discord/Slack

DRY_RUN=0
VERBOSE=0
while [[ $# -gt 0 ]]; do
    case "$1" in
        --dry-run) DRY_RUN=1; shift ;;
        --verbose) VERBOSE=1; shift ;;
        -h|--help) sed -n '2,/^# ====/p' "$0"; exit 0 ;;
        *) echo "unknown arg: $1" >&2; exit 1 ;;
    esac
done

ts() { date -Is; }
log() { printf '[%s] %s\n' "$(ts)" "$*" >>"$STATE_LOG"; [[ $VERBOSE -eq 1 ]] && printf '%s\n' "$*"; }

# --- Pre-flight --------------------------------------------------------------
if [[ ! -r "$LOG" ]]; then
    log "FAIL access log unreadable: $LOG"
    exit 1
fi

# Whitelist IPs (one per line; comments/blank ignored). Pulled out as a regex
# alternation that awk can use as an "if not in whitelist" check.
declare -A WHITE
if [[ -f "$WHITELIST" ]]; then
    while IFS= read -r line; do
        ip="${line%%#*}"            # strip comments
        ip="${ip%% *}"              # strip trailing space/notes
        ip="${ip%;}"                # strip nginx ;
        # accept "allow x.x.x.x" syntax too
        ip="${ip#allow }"
        ip="${ip## }"
        [[ -z "$ip" ]] && continue
        WHITE["$ip"]=1
    done <"$WHITELIST"
fi

# Use awk for the heavy lifting: it parses 50k log lines in well under a second.
# We treat the FIRST field as the client IP (combined log format) and the
# 9th field as the status code. Adjust if your log format differs.
NOW=$(date +%s)

mapfile -t RAW < <(awk -v now="$NOW" -v window="$WINDOW_SECONDS" '
{
    ip=$1
    # $4 = "[25/Apr/2026:13:45:00"
    ts=$4; gsub(/[\[]/,"",ts);
    # convert to epoch via "date -d" externally is too slow per line.
    # Instead, parse manually: dd/Mon/yyyy:HH:MM:SS
    if (match(ts, /^([0-9]{2})\/([A-Za-z]{3})\/([0-9]{4}):([0-9]{2}):([0-9]{2}):([0-9]{2})/, m)) {
        # awk has no good strptime; use a constant month map.
        mo["Jan"]=1;mo["Feb"]=2;mo["Mar"]=3;mo["Apr"]=4;mo["May"]=5;mo["Jun"]=6
        mo["Jul"]=7;mo["Aug"]=8;mo["Sep"]=9;mo["Oct"]=10;mo["Nov"]=11;mo["Dec"]=12
        # mktime needs "YYYY MM DD HH MM SS"
        epoch = mktime(sprintf("%04d %02d %02d %02d %02d %02d", m[3], mo[m[2]], m[1], m[4], m[5], m[6]))
    } else { next }
    if (now - epoch > window) next

    status = $9 + 0
    count[ip]++
    if (status >= 400) errs[ip]++
    if (status == 444) flagged[ip]++
}
END {
    for (ip in count) {
        printf "%s\t%d\t%d\t%d\n", ip, count[ip], errs[ip]+0, flagged[ip]+0
    }
}' "$LOG")

# --- Build new blocklist -----------------------------------------------------
TMP=$(mktemp)
trap 'rm -f "$TMP"' EXIT

declare -i blocked=0 considered=${#RAW[@]}
declare -A ALREADY
# Preserve manual entries already in the blocklist (lines like "# manual: ...")
if [[ -f "$BLOCKLIST" ]]; then
    while IFS= read -r line; do
        if [[ "$line" =~ ^#\ manual: ]]; then
            echo "$line" >>"$TMP"
            # Also keep the next deny line
            continue
        fi
    done <"$BLOCKLIST"
fi

{
    echo "# Auto-generated $(ts) by ddos-behavior-engine.sh"
    echo "# Window: ${WINDOW_SECONDS}s · req-threshold: ${REQUESTS_THRESHOLD} · err-threshold: ${ERROR_THRESHOLD}"
} >>"$TMP"

while IFS=$'\t' read -r ip count errs flagged; do
    [[ -z "$ip" ]] && continue
    if [[ -n "${WHITE[$ip]:-}" ]]; then
        log "skip (whitelist) $ip count=$count errs=$errs flagged=$flagged"
        continue
    fi
    block=0
    reason=""
    if (( count > REQUESTS_THRESHOLD )); then
        block=1; reason="rate>$REQUESTS_THRESHOLD"
    elif (( errs > ERROR_THRESHOLD )); then
        block=1; reason="err>$ERROR_THRESHOLD"
    elif (( flagged > 0 )); then
        block=1; reason="prior-444"
    fi
    if (( block == 1 )); then
        echo "deny $ip;  # $reason  count=$count errs=$errs"  >>"$TMP"
        blocked+=1
        ALREADY["$ip"]=1
        log "block $ip ($reason) count=$count errs=$errs"
    fi
done <<<"$(printf '%s\n' "${RAW[@]}")"

# --- Apply -------------------------------------------------------------------
if [[ $DRY_RUN -eq 1 ]]; then
    log "DRY RUN — would block $blocked IPs"
    [[ $VERBOSE -eq 1 ]] && cat "$TMP"
    exit 0
fi

# Atomic swap.
mv "$TMP" "$BLOCKLIST"
chmod 0644 "$BLOCKLIST"

# Update meta
{
    printf '{"generated_at":"%s","blocked":%d,"considered":%d,"window_s":%d}\n' \
        "$(ts)" "$blocked" "$considered" "$WINDOW_SECONDS"
} >"$META" 2>/dev/null || true

# Reload (the include directive must be present in your http {} block).
if nginx -t >/dev/null 2>&1; then
    nginx -s reload
    log "reloaded nginx — total blocked=$blocked considered=$considered"
else
    log "ERR nginx -t failed; skipped reload. Blocklist still updated."
    exit 1
fi

# Optional alert
if [[ -n "$ALERT_WEBHOOK_URL" && $blocked -gt 0 ]]; then
    curl -fsS --max-time 5 -X POST -H 'Content-Type: application/json' \
         -d "$(printf '{"content":"🛡️ ddos-behavior-engine blocked %d IPs (window %ds, threshold %d) on %s"}' \
                "$blocked" "$WINDOW_SECONDS" "$REQUESTS_THRESHOLD" "$(hostname)")" \
         "$ALERT_WEBHOOK_URL" >/dev/null || true
fi
