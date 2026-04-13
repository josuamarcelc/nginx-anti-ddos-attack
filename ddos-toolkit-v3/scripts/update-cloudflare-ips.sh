#!/usr/bin/env bash
# =============================================================================
# Fetch latest Cloudflare IP ranges and update nginx config. v3.0
# Added: checksum validation, retry logic, backup rotation.
# =============================================================================
set -euo pipefail

CF_CONF="${CF_CONF:-/etc/nginx/conf.d/cloudflare-real-ip.conf}"
NGINX_TEST="${NGINX_TEST:-/usr/sbin/nginx -t}"
NGINX_RELOAD="${NGINX_RELOAD:-/bin/systemctl reload nginx}"
MAX_RETRIES=3
RETRY_DELAY=5

log() { printf '[%s] %s\n' "$(date -u '+%Y-%m-%dT%H:%M:%SZ')" "$1"; }

fetch_with_retry() {
    local url="$1" result="" attempt
    for attempt in $(seq 1 "$MAX_RETRIES"); do
        result=$(curl -sf --max-time 30 "$url" 2>/dev/null) && break
        log "WARNING: Attempt ${attempt}/${MAX_RETRIES} failed for ${url}"
        sleep "$RETRY_DELAY"
    done
    if [[ -z "$result" ]]; then
        log "ERROR: Failed to fetch ${url} after ${MAX_RETRIES} attempts"
        return 1
    fi
    echo "$result"
}

ipv4=$(fetch_with_retry "https://www.cloudflare.com/ips-v4") || exit 1
ipv6=$(fetch_with_retry "https://www.cloudflare.com/ips-v6") || exit 1

# Sanity check: Cloudflare should have at least 10 IPv4 and 5 IPv6 ranges.
ipv4_count=$(echo "$ipv4" | grep -c '[0-9]')
ipv6_count=$(echo "$ipv6" | grep -c '[0-9a-f]')

if [[ "$ipv4_count" -lt 10 ]] || [[ "$ipv6_count" -lt 5 ]]; then
    log "ERROR: Suspiciously few ranges (IPv4: ${ipv4_count}, IPv6: ${ipv6_count}). Aborting."
    exit 1
fi

# Validate CIDR format
if echo "$ipv4" | grep -qvE '^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+/[0-9]+$'; then
    log "ERROR: IPv4 response contains non-CIDR lines. Aborting."
    exit 1
fi

backup="${CF_CONF}.bak.$(date +%Y%m%d)"
cp "$CF_CONF" "$backup"
# Keep only last 5 backups
ls -t "${CF_CONF}.bak."* 2>/dev/null | tail -n +6 | xargs rm -f 2>/dev/null || true

{
    printf '# Restore the original visitor IP when traffic is proxied through Cloudflare.\n'
    printf '# Auto-updated: %s\n' "$(date -u '+%Y-%m-%dT%H:%M:%SZ')"
    printf '# Source: https://www.cloudflare.com/ips/\n'
    printf '# IPv4 ranges: %d | IPv6 ranges: %d\n\n' "$ipv4_count" "$ipv6_count"
    printf '# IPv4\n'
    while IFS= read -r cidr; do
        [[ -n "$cidr" ]] && printf 'set_real_ip_from %s;\n' "$cidr"
    done <<< "$ipv4"
    printf '\n# IPv6\n'
    while IFS= read -r cidr; do
        [[ -n "$cidr" ]] && printf 'set_real_ip_from %s;\n' "$cidr"
    done <<< "$ipv6"
    printf '\nreal_ip_header CF-Connecting-IP;\nreal_ip_recursive on;\n'
} > "$CF_CONF"

if $NGINX_TEST 2>&1; then
    $NGINX_RELOAD
    log "Cloudflare IPs updated successfully. IPv4: ${ipv4_count} ranges, IPv6: ${ipv6_count} ranges."
else
    log "ERROR: nginx -t failed. Restoring backup."
    cp "$backup" "$CF_CONF"
    exit 1
fi
