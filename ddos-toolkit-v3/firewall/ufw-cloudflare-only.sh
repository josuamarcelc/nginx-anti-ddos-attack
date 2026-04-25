#!/usr/bin/env bash
# =============================================================================
# Origin Lockdown — only Cloudflare IPs can reach ports 80/443
# =============================================================================
# WITHOUT this, your DDoS rules are bypassable: anyone who finds the origin IP
# can ignore Cloudflare entirely. UFW is the simplest "deny everything except
# the orange cloud" implementation. iptables/nftables work the same way; pick
# one and stick with it.
#
# Usage:
#   sudo ./ufw-cloudflare-only.sh           # apply
#   sudo ./ufw-cloudflare-only.sh --dry-run # show every rule, change nothing
#   sudo ./ufw-cloudflare-only.sh --ssh-port 2222
#
# IMPORTANT: this RESETS your UFW table. Existing custom allow rules are
# wiped. If you have anything beyond SSH that needs ingress (e.g. a database
# port for backups), add it after the SSH allow below.
# =============================================================================
set -euo pipefail

DRY_RUN=0
SSH_PORT=22
EXTRA_ALLOWS=()

while [[ $# -gt 0 ]]; do
    case "$1" in
        --dry-run) DRY_RUN=1; shift ;;
        --ssh-port) SSH_PORT="$2"; shift 2 ;;
        --allow) EXTRA_ALLOWS+=("$2"); shift 2 ;;
        -h|--help)
            sed -n '2,/^# ====/p' "$0"; exit 0 ;;
        *) echo "unknown arg: $1" >&2; exit 1 ;;
    esac
done

if [[ $EUID -ne 0 ]]; then echo "run as root" >&2; exit 1; fi
if ! command -v ufw >/dev/null 2>&1; then
    echo "ufw is not installed. apt install ufw" >&2; exit 1
fi

run() {
    if [[ $DRY_RUN -eq 1 ]]; then
        printf '  DRY  %s\n' "$*"
    else
        printf '  RUN  %s\n' "$*"
        eval "$@"
    fi
}

echo "[+] Origin lockdown — UFW + Cloudflare allowlist"
[[ $DRY_RUN -eq 1 ]] && echo "    DRY RUN — no changes will be made"

run ufw --force reset
run ufw default deny incoming
run ufw default allow outgoing

# SSH first — never reset UFW without SSH allowed, you'll lock yourself out.
run ufw allow "${SSH_PORT}/tcp" comment '"ssh"'

# Optional extra ingress (e.g. --allow "5432/tcp from 10.0.0.5")
for extra in "${EXTRA_ALLOWS[@]}"; do
    run ufw allow $extra
done

# Cloudflare IPv4
echo "[+] Fetching Cloudflare IPv4 list..."
v4_list=$(curl -fsS --max-time 10 https://www.cloudflare.com/ips-v4 || true)
if [[ -z "$v4_list" ]]; then
    echo "[!] Failed to fetch Cloudflare IPv4 — aborting (would have blocked all web traffic)" >&2
    exit 1
fi
while IFS= read -r ip; do
    [[ -z "$ip" ]] && continue
    run ufw allow proto tcp from "$ip" to any port 80,443 comment '"cloudflare-v4"'
done <<<"$v4_list"

# Cloudflare IPv6 (best-effort: skip if IPv6 isn't enabled on the host)
echo "[+] Fetching Cloudflare IPv6 list..."
v6_list=$(curl -fsS --max-time 10 https://www.cloudflare.com/ips-v6 || true)
if [[ -n "$v6_list" ]]; then
    while IFS= read -r ip; do
        [[ -z "$ip" ]] && continue
        run ufw allow proto tcp from "$ip" to any port 80,443 comment '"cloudflare-v6"'
    done <<<"$v6_list"
else
    echo "[!] No IPv6 list (or IPv6 not enabled) — skipping"
fi

# Enable last.
run ufw --force enable

if [[ $DRY_RUN -eq 0 ]]; then
    echo
    echo "[+] Active rules:"
    ufw status numbered | head -30
    echo
    echo "[+] Done. Direct-IP probes now hit a closed port."
    echo "    Refresh CF list weekly: re-run this script (Cloudflare adds new ranges)."
fi
