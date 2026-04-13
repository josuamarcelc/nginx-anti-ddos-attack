#!/usr/bin/env bash
set -euo pipefail

PATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"

ACCESS_LOG="${ACCESS_LOG:-/var/log/nginx/access.log}"
GENERATED_BLOCKLIST="${GENERATED_BLOCKLIST:-/etc/nginx/ddos-blocklist-generated.conf}"
LOCK_FILE="${LOCK_FILE:-/run/ddos-nginx-autoblock.lock}"
SCAN_LINES="${SCAN_LINES:-20000}"
MIN_HITS="${MIN_HITS:-20}"
MAX_NEW_IPS="${MAX_NEW_IPS:-2000}"
SUBNET_MIN_IPS="${SUBNET_MIN_IPS:-25}"
NGINX_TEST="${NGINX_TEST:-/usr/sbin/nginx -t}"
NGINX_RELOAD="${NGINX_RELOAD:-/bin/systemctl reload nginx}"
DRY_RUN=0

for arg in "$@"; do
	case "$arg" in
		--dry-run) DRY_RUN=1 ;;
		--help|-h)
			printf '%s\n' "Usage: $0 [--dry-run]"
			printf '%s\n' "Env: ACCESS_LOG SCAN_LINES MIN_HITS MAX_NEW_IPS SUBNET_MIN_IPS GENERATED_BLOCKLIST"
			exit 0
			;;
		*) printf 'Unknown argument: %s\n' "$arg" >&2; exit 2 ;;
	esac
done

if [[ ! -r "$ACCESS_LOG" ]]; then
	printf 'Access log not readable: %s\n' "$ACCESS_LOG" >&2
	exit 1
fi

mkdir -p "$(dirname "$GENERATED_BLOCKLIST")"
touch "$GENERATED_BLOCKLIST"

exec 9>"$LOCK_FILE"
if ! flock -n 9; then
	printf 'Another ddos-nginx-autoblock run is already active.\n' >&2
	exit 0
fi

workdir="$(mktemp -d)"
trap 'rm -rf "$workdir"' EXIT

existing_ips="$workdir/existing_ips"
new_ips="$workdir/new_ips"
new_subnets="$workdir/new_subnets"
merged_ips="$workdir/merged_ips"
candidate="$workdir/ddos-blocklist-generated.conf"
backup="$workdir/ddos-blocklist-generated.backup"

awk '
	$1 ~ /^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+(\/[0-9]+)?$/ {print $1}
	$1 ~ /^[0-9a-fA-F:]+(\/[0-9]+)?$/ && $1 ~ /:/ {print $1}
' "$GENERATED_BLOCKLIST" | sort -u > "$existing_ips"

tail -n "$SCAN_LINES" "$ACCESS_LOG" | awk -v min_hits="$MIN_HITS" '
function suspicious_uri(uri) {
	return uri ~ /^\/\?([A-Za-z0-9]{1,16}=|=)?[A-Za-z0-9]{6,64}$/
}
function public_ipv4(ip, octets) {
	if (ip !~ /^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$/) return 0
	split(ip, octets, ".")
	if (octets[1] == 10) return 0
	if (octets[1] == 127) return 0
	if (octets[1] == 169 && octets[2] == 254) return 0
	if (octets[1] == 172 && octets[2] >= 16 && octets[2] <= 31) return 0
	if (octets[1] == 192 && octets[2] == 168) return 0
	return 1
}
function public_ipv6(ip) {
	if (ip !~ /:/) return 0
	if (ip ~ /^::1$/) return 0
	if (tolower(ip) ~ /^fc|^fd|^fe80/) return 0
	return 1
}
{
	ip = $1
	uri = $7
	status = $9
	if (suspicious_uri(uri) && (public_ipv4(ip) || public_ipv6(ip))) {
		hits[ip]++
	}
}
END {
	for (ip in hits) {
		if (hits[ip] >= min_hits) print ip
	}
}' | sort -u | head -n "$MAX_NEW_IPS" > "$new_ips"

awk -v subnet_min_ips="$SUBNET_MIN_IPS" '
	$0 ~ /^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$/ {
		split($0, octets, ".")
		subnet = octets[1] "." octets[2] "." octets[3] ".0/24"
		seen[subnet, $0] = 1
		subnets[subnet] = 1
	}
	END {
		for (subnet in subnets) {
			count = 0
			for (key in seen) {
				split(key, parts, SUBSEP)
				if (parts[1] == subnet) count++
			}
			if (count >= subnet_min_ips) print subnet
		}
	}
' "$new_ips" | sort -u > "$new_subnets"

sort -u "$existing_ips" "$new_ips" "$new_subnets" > "$merged_ips"

{
	printf '%s\n' "# This file is managed by /usr/local/sbin/ddos-nginx-autoblock.sh."
	printf '# Last generated: '
	date -u '+%Y-%m-%dT%H:%M:%SZ'
	printf '%s\n' "# Manual edits may be overwritten."
	while IFS= read -r ip; do
		[[ -z "$ip" ]] && continue
		printf '%s 1;\n' "$ip"
	done < "$merged_ips"
} > "$candidate"

if cmp -s "$candidate" "$GENERATED_BLOCKLIST"; then
	printf 'No blocklist changes. Existing entries: %s\n' "$(wc -l < "$merged_ips")"
	exit 0
fi

if [[ "$DRY_RUN" -eq 1 ]]; then
	printf 'Dry run: would add %s candidate IP(s) and %s candidate subnet(s). Total generated entries: %s\n' "$(wc -l < "$new_ips")" "$(wc -l < "$new_subnets")" "$(wc -l < "$merged_ips")"
	sed -n '1,40p' "$candidate"
	exit 0
fi

cp "$GENERATED_BLOCKLIST" "$backup"
install -m 0644 "$candidate" "$GENERATED_BLOCKLIST"

if $NGINX_TEST; then
	$NGINX_RELOAD
	printf 'Updated %s. Candidate IPs: %s. Candidate subnets: %s. Total generated entries: %s\n' "$GENERATED_BLOCKLIST" "$(wc -l < "$new_ips")" "$(wc -l < "$new_subnets")" "$(wc -l < "$merged_ips")"
else
	printf 'nginx -t failed after updating %s; restoring previous generated blocklist.\n' "$GENERATED_BLOCKLIST" >&2
	install -m 0644 "$backup" "$GENERATED_BLOCKLIST"
	exit 1
fi
