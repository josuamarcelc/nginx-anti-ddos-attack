#!/usr/bin/env bash
# =============================================================================
# DDoS Toolkit v3.0 — Automated Installer
# =============================================================================
# Usage: sudo ./install.sh [--uninstall]
# =============================================================================
set -euo pipefail

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

log()  { printf "${GREEN}[+]${NC} %s\n" "$1"; }
warn() { printf "${YELLOW}[!]${NC} %s\n" "$1"; }
err()  { printf "${RED}[✗]${NC} %s\n" "$1" >&2; }

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# --- Pre-flight checks ---
if [[ $EUID -ne 0 ]]; then
    err "This script must be run as root (sudo ./install.sh)"
    exit 1
fi

if ! command -v nginx >/dev/null 2>&1; then
    err "nginx is not installed. Install nginx first."
    exit 1
fi

# --- Uninstall mode ---
if [[ "${1:-}" == "--uninstall" ]]; then
    warn "Uninstalling DDoS Toolkit v3..."
    rm -f /etc/nginx/conf.d/cloudflare-real-ip.conf
    rm -f /etc/nginx/conf.d/ddos-global.conf
    rm -f /etc/nginx/snippets/ddos-global.conf
    rm -f /etc/nginx/snippets/ddos-auth.conf
    rm -f /etc/nginx/snippets/ddos-post.conf
    rm -f /etc/nginx/snippets/ddos-download.conf
    rm -f /etc/nginx/conf.d/cache-global.conf
    rm -f /etc/nginx/snippets/cache-static.conf
    rm -f /etc/nginx/snippets/cache-proxy.conf
    rm -f /etc/nginx/snippets/cache-microcache.conf
    rm -f /usr/local/sbin/cache-warmup.sh
    rm -rf /var/cache/nginx/proxy /var/cache/nginx/proxy_temp
    rm -f /etc/nginx/ddos-blocklist-generated.conf
    rm -f /etc/nginx/ddos-blocklist-meta.json
    rm -f /etc/nginx/ddos-whitelist.conf
    rm -f /usr/local/sbin/ddos-nginx-autoblock.sh
    rm -f /usr/local/sbin/update-cloudflare-ips.sh
    rm -f /etc/cron.d/ddos-nginx-autoblock
    rm -f /etc/logrotate.d/ddos-toolkit
    rm -f /etc/sysctl.d/99-ddos-hardening.conf
    warn "Removed all DDoS Toolkit files. Run 'nginx -t && systemctl reload nginx' and 'sysctl --system'."
    exit 0
fi

log "Installing DDoS Toolkit v3.0..."

# --- Backup existing files ---
BACKUP_DIR="/etc/nginx/ddos-backup-$(date +%Y%m%d-%H%M%S)"
mkdir -p "$BACKUP_DIR"
for f in /etc/nginx/conf.d/ddos-global.conf /etc/nginx/snippets/ddos-global.conf \
         /etc/nginx/snippets/ddos-auth.conf /etc/nginx/snippets/ddos-post.conf \
         /etc/nginx/ddos-blocklist-generated.conf /etc/nginx/ddos-whitelist.conf; do
    [[ -f "$f" ]] && cp "$f" "$BACKUP_DIR/" && warn "Backed up: $f"
done
log "Backups saved to $BACKUP_DIR"

# --- Create required directories ---
mkdir -p /etc/nginx/conf.d /etc/nginx/snippets

# --- Copy nginx configs ---
install -m 0644 "$SCRIPT_DIR/config/nginx/conf.d/cloudflare-real-ip.conf" /etc/nginx/conf.d/
install -m 0644 "$SCRIPT_DIR/config/nginx/conf.d/ddos-global.conf" /etc/nginx/conf.d/
install -m 0644 "$SCRIPT_DIR/config/nginx/snippets/ddos-global.conf" /etc/nginx/snippets/
install -m 0644 "$SCRIPT_DIR/config/nginx/snippets/ddos-auth.conf" /etc/nginx/snippets/
install -m 0644 "$SCRIPT_DIR/config/nginx/snippets/ddos-post.conf" /etc/nginx/snippets/
install -m 0644 "$SCRIPT_DIR/config/nginx/snippets/ddos-download.conf" /etc/nginx/snippets/
log "Nginx DDoS configs installed."

# --- Copy cache configs ---
install -m 0644 "$SCRIPT_DIR/config/nginx/conf.d/cache-global.conf" /etc/nginx/conf.d/
install -m 0644 "$SCRIPT_DIR/config/nginx/snippets/cache-static.conf" /etc/nginx/snippets/
install -m 0644 "$SCRIPT_DIR/config/nginx/snippets/cache-proxy.conf" /etc/nginx/snippets/
install -m 0644 "$SCRIPT_DIR/config/nginx/snippets/cache-microcache.conf" /etc/nginx/snippets/
log "Nginx cache configs installed."

# --- Create proxy cache directory ---
mkdir -p /var/cache/nginx/proxy /var/cache/nginx/proxy_temp
chown -R www-data:www-data /var/cache/nginx
log "Proxy cache directories created."

# --- Blocklist + whitelist (don't overwrite existing) ---
if [[ ! -f /etc/nginx/ddos-blocklist-generated.conf ]]; then
    install -m 0644 "$SCRIPT_DIR/config/nginx/ddos-blocklist-generated.conf" /etc/nginx/
    log "Created empty blocklist."
else
    warn "Existing blocklist preserved: /etc/nginx/ddos-blocklist-generated.conf"
fi

if [[ ! -f /etc/nginx/ddos-whitelist.conf ]]; then
    install -m 0644 "$SCRIPT_DIR/config/nginx/ddos-whitelist.conf" /etc/nginx/
    warn "Created whitelist template — EDIT THIS: /etc/nginx/ddos-whitelist.conf"
else
    warn "Existing whitelist preserved: /etc/nginx/ddos-whitelist.conf"
fi

# --- Initialize meta file ---
if [[ ! -f /etc/nginx/ddos-blocklist-meta.json ]]; then
    echo '' > /etc/nginx/ddos-blocklist-meta.json
    chmod 0644 /etc/nginx/ddos-blocklist-meta.json
fi

# --- Scripts ---
install -m 0755 "$SCRIPT_DIR/scripts/ddos-nginx-autoblock.sh" /usr/local/sbin/
install -m 0755 "$SCRIPT_DIR/scripts/update-cloudflare-ips.sh" /usr/local/sbin/
install -m 0755 "$SCRIPT_DIR/scripts/cache-warmup.sh" /usr/local/sbin/
log "Scripts installed to /usr/local/sbin/"

# --- Cron ---
install -m 0644 "$SCRIPT_DIR/config/cron/ddos-nginx-autoblock" /etc/cron.d/
log "Cron jobs installed."

# --- Log rotation ---
install -m 0644 "$SCRIPT_DIR/config/logrotate/ddos-toolkit" /etc/logrotate.d/
log "Logrotate config installed."

# --- Sysctl kernel hardening ---
install -m 0644 "$SCRIPT_DIR/config/sysctl/99-ddos-hardening.conf" /etc/sysctl.d/
log "Sysctl hardening config installed."

# --- Create log files ---
touch /var/log/ddos-nginx-autoblock.log
touch /var/log/update-cloudflare-ips.log
touch /var/log/nginx/ddos-blocked.log

# --- Apply sysctl ---
warn "Applying sysctl settings..."
if sysctl --system >/dev/null 2>&1; then
    log "Sysctl settings applied."
else
    warn "Some sysctl settings may have failed (conntrack module may not be loaded). Check manually."
fi

# --- Test nginx ---
log "Testing nginx configuration..."
if nginx -t 2>&1; then
    log "Nginx config OK."
else
    err "Nginx config test FAILED. Check the output above."
    err "Restoring backups from $BACKUP_DIR..."
    for f in "$BACKUP_DIR"/*; do
        [[ -f "$f" ]] && cp "$f" "/etc/nginx/$(basename "$f")"
    done
    exit 1
fi

echo ""
log "========================================="
log " DDoS Toolkit v3.0 installed successfully"
log "========================================="
echo ""
warn "NEXT STEPS:"
echo "  1. Edit your whitelist: nano /etc/nginx/ddos-whitelist.conf"
echo "     Add your server IP, monitoring IPs, office/VPN IPs."
echo ""
echo "  2. Add to each static site server {} block:"
echo "     include snippets/ddos-global.conf;"
echo "     include snippets/cache-static.conf;"
echo ""
echo "  3. Pre-compress your static assets (huge DDoS resilience boost):"
echo "     cache-warmup.sh /var/www/yoursite"
echo ""
echo "  4. Optional: mount proxy cache on RAM (see config/tmpfs/cache-tmpfs.fstab):"
echo "     echo 'tmpfs /var/cache/nginx tmpfs defaults,size=512m,mode=0755,uid=www-data,gid=www-data 0 0' >> /etc/fstab"
echo "     mount /var/cache/nginx"
echo ""
echo "  5. Uncomment HSTS header in snippets/ddos-global.conf if fully HTTPS."
echo ""
echo "  6. Set alerting (optional):"
echo "     export ALERT_WEBHOOK_URL='https://hooks.slack.com/services/...' in cron"
echo "     export ALERT_EMAIL='ops@example.com' in cron"
echo ""
echo "  7. Reload nginx:"
echo "     systemctl reload nginx"
echo ""
echo "  8. Test auto-blocker:"
echo "     /usr/local/sbin/ddos-nginx-autoblock.sh --dry-run --verbose"
echo ""
echo "  See config/nginx/examples/static-site.conf for a complete vhost example."
echo ""
