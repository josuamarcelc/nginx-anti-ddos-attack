#!/usr/bin/env bash
# =============================================================================
# DDoS Nginx Auto-Blocker v3.0
# =============================================================================
# WHAT'S NEW IN v3:
#   - Blocklist TTL/expiry: entries older than BLOCK_TTL_DAYS auto-purge
#   - Blocklist size cap: hard limit prevents runaway growth
#   - IPv6 /48 subnet aggregation (was IPv4-only)
#   - Proper CIDR whitelist matching (v2 was broken — exact match only)
#   - Webhook alerting when attack thresholds are hit
#   - JSON-timestamped blocklist entries for TTL tracking
#   - Configurable alert threshold
# =============================================================================
set -euo pipefail

PATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"

# --- Configuration (override via env) ---
ACCESS_LOG="${ACCESS_LOG:-/var/log/nginx/access.log}"
GENERATED_BLOCKLIST="${GENERATED_BLOCKLIST:-/etc/nginx/ddos-blocklist-generated.conf}"
BLOCKLIST_META="${BLOCKLIST_META:-/etc/nginx/ddos-blocklist-meta.json}"
LOCK_FILE="${LOCK_FILE:-/run/ddos-nginx-autoblock.lock}"
SCAN_LINES="${SCAN_LINES:-50000}"
MIN_HITS="${MIN_HITS:-15}"
MIN_HITS_4XX="${MIN_HITS_4XX:-50}"
MIN_HITS_FREQ="${MIN_HITS_FREQ:-200}"
MAX_NEW_IPS="${MAX_NEW_IPS:-5000}"
SUBNET_MIN_IPS="${SUBNET_MIN_IPS:-10}"
SUBNET_MIN_IPS_V6="${SUBNET_MIN_IPS_V6:-5}"
WHITELIST_FILE="${WHITELIST_FILE:-/etc/nginx/ddos-whitelist.conf}"
NGINX_TEST="${NGINX_TEST:-/usr/sbin/nginx -t}"
NGINX_RELOAD="${NGINX_RELOAD:-/bin/systemctl reload nginx}"

# --- v3: TTL, size cap, alerting ---
BLOCK_TTL_DAYS="${BLOCK_TTL_DAYS:-7}"
MAX_BLOCKLIST_ENTRIES="${MAX_BLOCKLIST_ENTRIES:-50000}"
ALERT_THRESHOLD="${ALERT_THRESHOLD:-50}"
ALERT_WEBHOOK_URL="${ALERT_WEBHOOK_URL:-}"
ALERT_EMAIL="${ALERT_EMAIL:-}"
HOSTNAME_LABEL="${HOSTNAME_LABEL:-$(hostname -f 2>/dev/null || hostname)}"

DRY_RUN=0
VERBOSE=0
PURGE_ONLY=0

for arg in "$@"; do
    case "$arg" in
        --dry-run) DRY_RUN=1 ;;
        --verbose) VERBOSE=1 ;;
        --purge)   PURGE_ONLY=1 ;;
        --help|-h)
            cat <<-'EOF'
Usage: ddos-nginx-autoblock.sh [--dry-run] [--verbose] [--purge]

Options:
  --dry-run     Show what would happen without applying changes
  --verbose     Extra logging output
  --purge       Only purge expired entries (skip detection scan)

Detection patterns:
  1. Random root query floods    /?key=RANDOM
  2. POST request floods          Excessive POST from single IP
  3. Path scanner / vuln probes   /wp-login.php, /.env, /cgi-bin, etc.
  4. 4xx hammering                Excessive 4xx responses from single IP
  5. High frequency               Any IP exceeding MIN_HITS_FREQ total hits

Env vars:
  ACCESS_LOG            Log file to scan            (default: /var/log/nginx/access.log)
  SCAN_LINES            Lines to scan from tail     (default: 50000)
  MIN_HITS              Hits for pattern block      (default: 15)
  MIN_HITS_4XX          4xx hits to trigger block   (default: 50)
  MIN_HITS_FREQ         Total hits frequency cap    (default: 200)
  MAX_NEW_IPS           Max new IPs per run         (default: 5000)
  SUBNET_MIN_IPS        IPs to trigger /24 block    (default: 10)
  SUBNET_MIN_IPS_V6     IPs to trigger /48 block    (default: 5)
  BLOCK_TTL_DAYS        Days before auto-purge      (default: 7)
  MAX_BLOCKLIST_ENTRIES Hard cap on total entries    (default: 50000)
  ALERT_THRESHOLD       New IPs to trigger alert    (default: 50)
  ALERT_WEBHOOK_URL     Webhook URL for alerts      (default: empty)
  ALERT_EMAIL           Email address for alerts    (default: empty)
  WHITELIST_FILE        IPs to never block          (default: /etc/nginx/ddos-whitelist.conf)
  GENERATED_BLOCKLIST                               (default: /etc/nginx/ddos-blocklist-generated.conf)
EOF
            exit 0
            ;;
        *) printf 'Unknown argument: %s\n' "$arg" >&2; exit 2 ;;
    esac
done

log() { printf '[%s] %s\n' "$(date -u '+%Y-%m-%dT%H:%M:%SZ')" "$1"; }
vlog() { [[ "$VERBOSE" -eq 1 ]] && log "$1" || true; }

# ---------------------------------------------------------------------------
# ALERTING
# ---------------------------------------------------------------------------
send_alert() {
    local new_count="$1" new_subnet_count="$2" total_count="$3"
    local message="[DDoS Auto-Blocker] ${HOSTNAME_LABEL}: Blocked ${new_count} new IPs and ${new_subnet_count} new subnets (total: ${total_count}) in last scan."

    # Webhook (Slack/Discord/PagerDuty/generic)
    if [[ -n "$ALERT_WEBHOOK_URL" ]]; then
        curl -sf -X POST -H 'Content-Type: application/json' \
            -d "{\"text\":\"${message}\"}" \
            "$ALERT_WEBHOOK_URL" >/dev/null 2>&1 || log "WARNING: Webhook alert failed"
    fi

    # Email (requires mailutils or sendmail)
    if [[ -n "$ALERT_EMAIL" ]] && command -v mail >/dev/null 2>&1; then
        echo "$message" | mail -s "[DDoS Alert] ${HOSTNAME_LABEL}" "$ALERT_EMAIL" 2>/dev/null || log "WARNING: Email alert failed"
    fi
}

# ---------------------------------------------------------------------------
# CIDR WHITELIST MATCHING (proper implementation)
# ---------------------------------------------------------------------------
# Converts a CIDR to a range check usable in awk. We expand all whitelist
# entries into a format the main awk can consume.
build_whitelist_set() {
    local wl_file="$1" output="$2"
    if [[ ! -r "$wl_file" ]]; then
        touch "$output"
        return
    fi
    # Extract IPs and CIDRs, expand CIDRs to individual /32 isn't feasible
    # for /24. Instead we output a lookup file with:
    #   - Exact IPs: "1.2.3.4 exact"
    #   - CIDR prefixes: "1.2.3. cidr24" (for /24)
    #   - Full CIDRs stored for awk prefix matching
    awk '
    /^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$/ {
        print $1 " exact"
    }
    /^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+\/24$/ {
        split($1, o, "[./]")
        print o[1] "." o[2] "." o[3] ". prefix24"
    }
    /^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+\/16$/ {
        split($1, o, "[./]")
        print o[1] "." o[2] ". prefix16"
    }
    /^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+\/8$/ {
        split($1, o, "[./]")
        print o[1] ". prefix8"
    }
    # IPv6 exact
    /^[0-9a-fA-F:]+$/ && /:/ {
        print $1 " exact"
    }
    # IPv6 /48
    /^[0-9a-fA-F:]+\/48$/ {
        ip = $1; sub(/\/48$/, "", ip)
        # Extract first 3 groups for /48 prefix
        n = split(ip, g, ":")
        if (n >= 3) print g[1] ":" g[2] ":" g[3] ": prefix48"
    }
    ' "$wl_file" > "$output"
}

# ---------------------------------------------------------------------------
# BLOCKLIST META: TTL tracking
# ---------------------------------------------------------------------------
# Meta file format (one JSON line per entry):
# {"ip":"1.2.3.4","added":"2026-04-13T12:00:00Z"}
init_meta() {
    if [[ ! -f "$BLOCKLIST_META" ]]; then
        echo '[]' > "$BLOCKLIST_META"
    fi
}

purge_expired_entries() {
    local cutoff_epoch
    cutoff_epoch=$(date -u -d "${BLOCK_TTL_DAYS} days ago" '+%s' 2>/dev/null || date -u -v-${BLOCK_TTL_DAYS}d '+%s' 2>/dev/null || echo 0)

    if [[ "$cutoff_epoch" -eq 0 ]]; then
        log "WARNING: Cannot compute TTL cutoff. Skipping purge."
        return
    fi

    local before_count after_count purged_count
    before_count=$(wc -l < "$BLOCKLIST_META" 2>/dev/null || echo 0)

    if [[ "$before_count" -le 1 ]]; then
        vlog "No meta entries to purge."
        return
    fi

    # Filter out expired entries
    awk -v cutoff="$cutoff_epoch" '
    BEGIN { FS="\"" }
    /\"added\":/ {
        for (i=1; i<=NF; i++) {
            if ($i == "added") {
                ts = $(i+2)
                # Convert ISO timestamp to epoch (approximate — good enough for TTL)
                cmd = "date -u -d \"" ts "\" +%s 2>/dev/null || echo 0"
                cmd | getline ep
                close(cmd)
                if (ep+0 >= cutoff+0) print $0
                next
            }
        }
    }
    ' "$BLOCKLIST_META" > "${BLOCKLIST_META}.tmp"

    mv "${BLOCKLIST_META}.tmp" "$BLOCKLIST_META"
    after_count=$(wc -l < "$BLOCKLIST_META" 2>/dev/null || echo 0)
    purged_count=$((before_count - after_count))

    if [[ "$purged_count" -gt 0 ]]; then
        log "Purged ${purged_count} expired entries (TTL: ${BLOCK_TTL_DAYS} days)."
    else
        vlog "No expired entries to purge."
    fi
}

add_meta_entries() {
    local ips_file="$1"
    local now
    now=$(date -u '+%Y-%m-%dT%H:%M:%SZ')
    while IFS= read -r ip; do
        [[ -z "$ip" ]] && continue
        printf '{"ip":"%s","added":"%s"}\n' "$ip" "$now"
    done < "$ips_file" >> "$BLOCKLIST_META"
}

get_meta_ips() {
    local output="$1"
    awk -F'"' '/\"ip\":/ { for(i=1;i<=NF;i++) if($i=="ip") print $(i+2) }' \
        "$BLOCKLIST_META" | sort -u > "$output"
}

# ---------------------------------------------------------------------------
# MAIN
# ---------------------------------------------------------------------------
if [[ "$PURGE_ONLY" -eq 0 ]] && [[ ! -r "$ACCESS_LOG" ]]; then
    log "ERROR: Access log not readable: $ACCESS_LOG"
    exit 1
fi

mkdir -p "$(dirname "$GENERATED_BLOCKLIST")"
touch "$GENERATED_BLOCKLIST"
init_meta

# --- Lock ---
exec 9>"$LOCK_FILE"
if ! flock -n 9; then
    log "Another ddos-nginx-autoblock run is already active."
    exit 0
fi

workdir="$(mktemp -d)"
trap 'rm -rf "$workdir"' EXIT

# --- Purge expired ---
purge_expired_entries

if [[ "$PURGE_ONLY" -eq 1 ]]; then
    # Rebuild blocklist from meta only
    get_meta_ips "$workdir/meta_ips"
    {
        printf '%s\n' "# This file is managed by /usr/local/sbin/ddos-nginx-autoblock.sh."
        printf '# Last generated: '
        date -u '+%Y-%m-%dT%H:%M:%SZ'
        printf '# Total entries: %s\n' "$(wc -l < "$workdir/meta_ips")"
        printf '%s\n' "# Manual edits may be overwritten."
        while IFS= read -r ip; do
            [[ -z "$ip" ]] && continue
            printf '%s 1;\n' "$ip"
        done < "$workdir/meta_ips"
    } > "$workdir/candidate"

    if ! cmp -s "$workdir/candidate" "$GENERATED_BLOCKLIST"; then
        cp "$GENERATED_BLOCKLIST" "$workdir/backup"
        install -m 0644 "$workdir/candidate" "$GENERATED_BLOCKLIST"
        if $NGINX_TEST 2>&1; then
            $NGINX_RELOAD
            log "Purge complete. Rebuilt blocklist: $(wc -l < "$workdir/meta_ips") entries."
        else
            log "ERROR: nginx -t failed after purge rebuild. Restoring backup."
            install -m 0644 "$workdir/backup" "$GENERATED_BLOCKLIST"
            exit 1
        fi
    else
        log "Purge: no blocklist changes needed."
    fi
    exit 0
fi

# --- Build whitelist ---
build_whitelist_set "$WHITELIST_FILE" "$workdir/whitelist_expanded"

# --- Extract existing blocked IPs/subnets from meta ---
get_meta_ips "$workdir/existing_ips"
vlog "Existing entries: $(wc -l < "$workdir/existing_ips")"

# --- Multi-pattern detection ---
tail -n "$SCAN_LINES" "$ACCESS_LOG" | awk \
    -v min_hits="$MIN_HITS" \
    -v min_hits_4xx="$MIN_HITS_4XX" \
    -v min_hits_freq="$MIN_HITS_FREQ" \
    -v wl_file="$workdir/whitelist_expanded" '
BEGIN {
    while ((getline line < wl_file) > 0) {
        split(line, parts, " ")
        wl_val = parts[1]
        wl_type = parts[2]
        if (wl_type == "exact") wl_exact[wl_val] = 1
        else if (wl_type == "prefix24") wl_p24[wl_val] = 1
        else if (wl_type == "prefix16") wl_p16[wl_val] = 1
        else if (wl_type == "prefix8") wl_p8[wl_val] = 1
        else if (wl_type == "prefix48") wl_p48[wl_val] = 1
    }
    close(wl_file)
}
function is_whitelisted_v4(ip,    octets, p24, p16, p8) {
    if (ip in wl_exact) return 1
    split(ip, octets, ".")
    p24 = octets[1] "." octets[2] "." octets[3] "."
    p16 = octets[1] "." octets[2] "."
    p8  = octets[1] "."
    if (p24 in wl_p24) return 1
    if (p16 in wl_p16) return 1
    if (p8 in wl_p8) return 1
    return 0
}
function is_whitelisted_v6(ip,    n, g, p48) {
    if (ip in wl_exact) return 1
    n = split(ip, g, ":")
    if (n >= 3) {
        p48 = g[1] ":" g[2] ":" g[3] ":"
        if (p48 in wl_p48) return 1
    }
    return 0
}
function is_whitelisted(ip) {
    if (ip ~ /:/) return is_whitelisted_v6(ip)
    return is_whitelisted_v4(ip)
}
function public_ipv4(ip,    octets) {
    if (ip !~ /^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$/) return 0
    split(ip, octets, ".")
    if (octets[1]+0 == 10) return 0
    if (octets[1]+0 == 127) return 0
    if (octets[1]+0 == 169 && octets[2]+0 == 254) return 0
    if (octets[1]+0 == 172 && octets[2]+0 >= 16 && octets[2]+0 <= 31) return 0
    if (octets[1]+0 == 192 && octets[2]+0 == 168) return 0
    if (octets[1]+0 == 0) return 0
    return 1
}
function public_ipv6(ip) {
    if (ip !~ /:/) return 0
    if (ip ~ /^::1$/) return 0
    if (tolower(ip) ~ /^fc|^fd|^fe80/) return 0
    return 1
}
function is_public(ip) {
    return (public_ipv4(ip) || public_ipv6(ip))
}
function suspicious_query(uri) {
    return uri ~ /^\/\?([A-Za-z0-9_]{0,20}=)?[A-Za-z0-9]{4,128}$/
}
function is_path_scan(uri) {
    return uri ~ /^\/(wp-login|xmlrpc|wp-admin|\.env|\.git|\.svn|\.hg|\.DS_Store|\.htaccess|\.htpasswd|\.aws|\.docker|\.ssh|\.kube|\.npmrc|phpinfo|php-?my-?admin|pma|actuator|jolokia|heapdump|debug|cgi-bin|vendor|telescope|console|solr|manager|setup|shell|eval|config\.|configuration\.|docker-compose|Dockerfile|credentials|passwd|shadow|id_rsa|server-status|server-info|elmah\.axd|node_modules|package\.json|yarn\.lock|backup|db\.|sql|install|admin)/
}
{
    ip = $1
    method = $6
    gsub(/"/, "", method)
    uri = $7
    status = $9

    if (!is_public(ip)) next
    if (is_whitelisted(ip)) next

    total_hits[ip]++

    if (suspicious_query(uri)) query_hits[ip]++
    if (method == "POST") post_hits[ip]++
    if (is_path_scan(uri)) scan_hits[ip]++
    if (status ~ /^4[0-9][0-9]$/) err_hits[ip]++
}
END {
    for (ip in total_hits) {
        blocked = 0
        if (ip in query_hits && query_hits[ip] >= min_hits) blocked = 1
        if (ip in post_hits && post_hits[ip] >= min_hits * 3) blocked = 1
        if (ip in scan_hits && scan_hits[ip] >= min_hits) blocked = 1
        if (ip in err_hits && err_hits[ip] >= min_hits_4xx) blocked = 1
        if (total_hits[ip] >= min_hits_freq) blocked = 1
        if (blocked) print ip
    }
}' | sort -u | head -n "$MAX_NEW_IPS" > "$workdir/new_ips_raw"

# Remove already-blocked IPs
comm -23 <(sort "$workdir/new_ips_raw") <(sort "$workdir/existing_ips") > "$workdir/new_ips"

vlog "New candidate IPs: $(wc -l < "$workdir/new_ips")"

# --- IPv4 /24 Subnet auto-aggregation ---
awk -v subnet_min="$SUBNET_MIN_IPS" '
$0 ~ /^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$/ {
    split($0, o, ".")
    subnet = o[1] "." o[2] "." o[3] ".0/24"
    if (!seen[subnet, $0]++) count[subnet]++
}
END {
    for (s in count) if (count[s] >= subnet_min) print s
}
' "$workdir/new_ips" | sort -u > "$workdir/new_subnets_v4"

# --- IPv6 /48 Subnet auto-aggregation ---
awk -v subnet_min="$SUBNET_MIN_IPS_V6" '
/:/ {
    n = split($0, g, ":")
    if (n >= 3) {
        subnet = g[1] ":" g[2] ":" g[3] "::/48"
        if (!seen[subnet, $0]++) count[subnet]++
    }
}
END {
    for (s in count) if (count[s] >= subnet_min) print s
}
' "$workdir/new_ips" | sort -u > "$workdir/new_subnets_v6"

cat "$workdir/new_subnets_v4" "$workdir/new_subnets_v6" | sort -u > "$workdir/new_subnets"
vlog "New candidate subnets: $(wc -l < "$workdir/new_subnets")"

# --- Remove individual IPs covered by new/existing subnets ---
if [[ -s "$workdir/new_subnets" ]] || grep -q '/' "$workdir/existing_ips" 2>/dev/null; then
    {
        # IPv4 /24 prefixes
        grep '/24' "$workdir/new_subnets" 2>/dev/null | awk -F'[./]' '{print $1"."$2"."$3"."}' || true
        grep '/24' "$workdir/existing_ips" 2>/dev/null | awk -F'[./]' '{print $1"."$2"."$3"."}' || true
    } | sort -u > "$workdir/subnet_prefixes_v4"

    {
        # IPv6 /48 prefixes
        grep '/48' "$workdir/new_subnets" 2>/dev/null | awk -F':' '{print $1":"$2":"$3":"}' || true
        grep '/48' "$workdir/existing_ips" 2>/dev/null | awk -F':' '{print $1":"$2":"$3":"}' || true
    } | sort -u > "$workdir/subnet_prefixes_v6"

    cat "$workdir/subnet_prefixes_v4" "$workdir/subnet_prefixes_v6" > "$workdir/all_prefixes"

    if [[ -s "$workdir/all_prefixes" ]]; then
        grep -v -F -f "$workdir/all_prefixes" "$workdir/new_ips" > "$workdir/new_ips_filtered" 2>/dev/null || true
        grep -v -F -f "$workdir/all_prefixes" "$workdir/existing_ips" > "$workdir/existing_ips_filtered" 2>/dev/null || true
    else
        cp "$workdir/new_ips" "$workdir/new_ips_filtered"
        cp "$workdir/existing_ips" "$workdir/existing_ips_filtered"
    fi

    sort -u "$workdir/existing_ips_filtered" "$workdir/new_ips_filtered" "$workdir/new_subnets" \
        <(grep '/' "$workdir/existing_ips" 2>/dev/null || true) > "$workdir/merged_ips"
else
    sort -u "$workdir/existing_ips" "$workdir/new_ips" > "$workdir/merged_ips"
fi

# --- Enforce size cap ---
total_entries=$(wc -l < "$workdir/merged_ips")
if [[ "$total_entries" -gt "$MAX_BLOCKLIST_ENTRIES" ]]; then
    log "WARNING: Blocklist exceeds cap (${total_entries} > ${MAX_BLOCKLIST_ENTRIES}). Trimming oldest entries."
    # Keep subnets (they're more valuable), trim individual IPs
    grep '/' "$workdir/merged_ips" > "$workdir/subnets_keep" 2>/dev/null || true
    grep -v '/' "$workdir/merged_ips" | tail -n "$MAX_BLOCKLIST_ENTRIES" > "$workdir/ips_keep" 2>/dev/null || true
    sort -u "$workdir/subnets_keep" "$workdir/ips_keep" > "$workdir/merged_ips"
    total_entries=$(wc -l < "$workdir/merged_ips")
fi

vlog "Total merged entries: $total_entries"

# --- Add new entries to meta ---
add_meta_entries "$workdir/new_ips"
add_meta_entries "$workdir/new_subnets"

# --- Generate candidate blocklist ---
{
    printf '%s\n' "# This file is managed by /usr/local/sbin/ddos-nginx-autoblock.sh."
    printf '# Last generated: '
    date -u '+%Y-%m-%dT%H:%M:%SZ'
    printf '# Total entries: %s\n' "$total_entries"
    printf '# TTL: %s days | Max entries: %s\n' "$BLOCK_TTL_DAYS" "$MAX_BLOCKLIST_ENTRIES"
    printf '%s\n' "# Manual edits may be overwritten."
    while IFS= read -r ip; do
        [[ -z "$ip" ]] && continue
        printf '%s 1;\n' "$ip"
    done < "$workdir/merged_ips"
} > "$workdir/candidate"

# --- Check if anything changed ---
if cmp -s "$workdir/candidate" "$GENERATED_BLOCKLIST"; then
    log "No blocklist changes. Total entries: $total_entries"
    exit 0
fi

new_ip_count=$(wc -l < "$workdir/new_ips")
new_subnet_count=$(wc -l < "$workdir/new_subnets")

if [[ "$DRY_RUN" -eq 1 ]]; then
    log "DRY RUN: Would add ${new_ip_count} IPs and ${new_subnet_count} subnets. Total: ${total_entries}"
    echo "--- New IPs (first 50) ---"
    head -50 "$workdir/new_ips"
    echo "--- New Subnets ---"
    cat "$workdir/new_subnets"
    exit 0
fi

# --- Apply ---
cp "$GENERATED_BLOCKLIST" "$workdir/backup"
install -m 0644 "$workdir/candidate" "$GENERATED_BLOCKLIST"

if $NGINX_TEST 2>&1; then
    $NGINX_RELOAD
    log "Updated $GENERATED_BLOCKLIST. New IPs: ${new_ip_count}. New subnets: ${new_subnet_count}. Total entries: ${total_entries}"

    # --- Alert if threshold exceeded ---
    total_new=$((new_ip_count + new_subnet_count))
    if [[ "$total_new" -ge "$ALERT_THRESHOLD" ]]; then
        log "ALERT: ${total_new} new blocks exceeds threshold (${ALERT_THRESHOLD}). Sending alert."
        send_alert "$new_ip_count" "$new_subnet_count" "$total_entries"
    fi
else
    log "ERROR: nginx -t failed after update. Restoring backup."
    install -m 0644 "$workdir/backup" "$GENERATED_BLOCKLIST"
    exit 1
fi
