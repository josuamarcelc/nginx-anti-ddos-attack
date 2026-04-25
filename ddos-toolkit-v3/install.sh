#!/usr/bin/env bash
# =============================================================================
# DDoS Toolkit v3 — installer
# =============================================================================
# Ruthlessly simple usage:
#
#   sudo ./install.sh                  install everything, just works
#   sudo ./install.sh --dry-run        show what would happen, write nothing
#   sudo ./install.sh --uninstall      use rollback.sh instead — see below
#
# Optional escape hatches (you almost never need these):
#   --no-sysctl       skip kernel sysctl apply
#   --no-fail2ban     skip fail2ban
#   --no-cron         skip cron
#   --no-cache        skip nginx caching configs
#   --apply-ufw       run firewall/ufw-cloudflare-only.sh as part of install (DESTRUCTIVE)
#
# Behavior the user gets without thinking about it:
#   - Detects existing nginx config and only writes files that don't conflict
#   - Backs up every overwritten file to /etc/nginx/ddos-backup-<timestamp>/
#   - Writes a manifest at /etc/nginx/ddos-toolkit-manifest-<timestamp>.txt
#     listing EVERY file installed + every file backed up, so rollback.sh can
#     reverse the install exactly
#   - Validates nginx -t at the end and auto-rolls-back the nginx pieces if it fails
#   - Never modifies UFW, fail2ban service state, or sysctl values without your knowledge
#
# Rollback to the previous state:
#   sudo ./rollback.sh                 reverses the most recent install
#   sudo ./rollback.sh --list          show all manifests on this server
# =============================================================================
set -euo pipefail

RED=$'\033[0;31m'
GREEN=$'\033[0;32m'
YELLOW=$'\033[1;33m'
CYAN=$'\033[0;36m'
GRAY=$'\033[0;90m'
NC=$'\033[0m'

DRY_RUN=0
SKIP_SYSCTL=0
SKIP_FAIL2BAN=0
SKIP_CRON=0
SKIP_CACHE=0
APPLY_UFW=0

while [[ $# -gt 0 ]]; do
    case "$1" in
        --dry-run)        DRY_RUN=1; shift ;;
        --uninstall)
            err=$(printf '%s\n' "Use rollback.sh — it reverses the most recent install precisely." \
                  "  sudo ./rollback.sh                 # roll back the most recent install" \
                  "  sudo ./rollback.sh --list          # list all manifests")
            printf "%s%s%s\n" "$RED" "$err" "$NC" >&2; exit 2 ;;
        --no-sysctl)      SKIP_SYSCTL=1; shift ;;
        --no-fail2ban)    SKIP_FAIL2BAN=1; shift ;;
        --no-cron)        SKIP_CRON=1; shift ;;
        --no-cache)       SKIP_CACHE=1; shift ;;
        --apply-ufw)      APPLY_UFW=1; shift ;;
        -h|--help)        sed -n '2,/^# ====/p' "$0"; exit 0 ;;
        *) echo "unknown arg: $1" >&2; exit 1 ;;
    esac
done

log()      { printf "%s[+]%s %s\n" "$GREEN"  "$NC" "$*"; }
warn()     { printf "%s[!]%s %s\n" "$YELLOW" "$NC" "$*"; }
err()      { printf "%s[✗]%s %s\n" "$RED"    "$NC" "$*" >&2; }
section()  { printf "\n%s═══ %s%s\n" "$CYAN" "$*" "$NC"; }
hint()     { printf "%s    %s%s\n" "$GRAY"   "$*" "$NC"; }

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# ---------------------------------------------------------------------------
# Pre-flight: must be root, nginx must exist
# ---------------------------------------------------------------------------
[[ $EUID -eq 0 ]] || { err "Run as root (sudo $0)"; exit 1; }
if ! command -v nginx >/dev/null 2>&1; then
    err "nginx is not installed. apt install nginx (or your distro equivalent), then re-run."
    exit 1
fi

NGINX_CONFD="/etc/nginx/conf.d"
NGINX_SNIP="/etc/nginx/snippets"
NGINX_DIR="/etc/nginx"
SBIN="/usr/local/sbin"

TS="$(date +%Y%m%d-%H%M%S)"
BACKUP_DIR="$NGINX_DIR/ddos-backup-$TS"
MANIFEST="$NGINX_DIR/ddos-toolkit-manifest-$TS.txt"
ROLLBACK_SCRIPT="$SCRIPT_DIR/rollback.sh"

# ---------------------------------------------------------------------------
# Manifest helpers — buffer in arrays, write the file once at the end.
# This avoids the subtle bug where appending out-of-order would land entries
# under the wrong [SECTION] header.
# ---------------------------------------------------------------------------
INSTALLED_FILES=()
OVERWRITTEN_FILES=()
ACTIONS=()

manifest_record_install()   { INSTALLED_FILES+=("$1"); }
manifest_record_overwrite() { OVERWRITTEN_FILES+=("$1|$2"); }
manifest_record_action()    { ACTIONS+=("$1"); }

manifest_finalize() {
    [[ $DRY_RUN -eq 1 ]] && { warn "DRY-RUN — would write manifest to $MANIFEST"; return; }
    {
        echo "# DDoS Toolkit v3 — install manifest"
        echo "# Generated: $(date -Is)"
        echo "INSTALL_TIMESTAMP=$TS"
        echo "TOOLKIT_DIR=$SCRIPT_DIR"
        echo "BACKUP_DIR=$BACKUP_DIR"
        echo "NGINX_VERSION=$(nginx -v 2>&1)"
        echo "DISTRO=$(grep -oE '^PRETTY_NAME=.*' /etc/os-release 2>/dev/null | head -1)"
        echo
        echo "# files this run added (rollback will rm them)"
        echo "[INSTALLED]"
        printf '%s\n' "${INSTALLED_FILES[@]+"${INSTALLED_FILES[@]}"}"
        echo
        echo "# files we replaced; rollback will restore from BACKUP_DIR"
        echo "[OVERWRITTEN]"
        printf '%s\n' "${OVERWRITTEN_FILES[@]+"${OVERWRITTEN_FILES[@]}"}"
        echo
        echo "# side-effects rollback should also reverse"
        echo "[ACTIONS]"
        printf '%s\n' "${ACTIONS[@]+"${ACTIONS[@]}"}"
    } > "$MANIFEST"
    chmod 0600 "$MANIFEST"
}

# ---------------------------------------------------------------------------
# Filesystem helpers
# ---------------------------------------------------------------------------
ddo() {
    if [[ $DRY_RUN -eq 1 ]]; then
        printf "  ${YELLOW}DRY${NC}  %s\n" "$*"
    else
        printf "  ${GREEN}RUN${NC}  %s\n" "$*"
        eval "$@"
    fi
}

# install_file <src> <dst>
#   - If dst exists with different content → back up first, record OVERWRITTEN.
#   - If dst doesn't exist → just install, record INSTALLED.
#   - If dst exists with identical content → skip (idempotent re-runs are noise-free).
install_file() {
    local src="$1" dst="$2" mode="${3:-0644}"
    if [[ ! -f "$src" ]]; then
        warn "skipped (source missing): $src"
        return 0
    fi
    # If dst is a directory, append basename
    if [[ -d "$dst" ]]; then
        dst="${dst%/}/$(basename "$src")"
    fi
    if [[ -f "$dst" ]] && cmp -s "$src" "$dst"; then
        hint "unchanged: $dst"
        return 0
    fi
    if [[ -f "$dst" ]]; then
        # Overwriting — back up first
        ddo "mkdir -p \"$BACKUP_DIR\""
        ddo "cp -p \"$dst\" \"$BACKUP_DIR/$(basename "$dst")\""
        manifest_record_overwrite "$dst" "$BACKUP_DIR/$(basename "$dst")"
    else
        manifest_record_install "$dst"
    fi
    ddo "install -m $mode \"$src\" \"$dst\""
}

# ---------------------------------------------------------------------------
# Compatibility detection: warn-not-fail when finding pre-existing toolkit
# bits. nginx is happy with duplicate set_real_ip_from / multiple zones (they
# just need different names), so by default the toolkit's files COEXIST with
# whatever's already there.
# ---------------------------------------------------------------------------
detect_environment() {
    section "Environment scan"

    log "Distro: $(grep -oE '^PRETTY_NAME=.*' /etc/os-release 2>/dev/null | cut -d= -f2 | tr -d '"' || echo unknown)"
    log "Nginx:  $(nginx -v 2>&1 | sed 's/.*\///')"
    log "Has UFW:        $(command -v ufw      >/dev/null && echo yes || echo no)"
    log "Has fail2ban:   $(command -v fail2ban-client >/dev/null && echo yes || echo no)"
    log "Has memcached:  $(command -v memcached >/dev/null && echo yes || echo no)"

    # Detect existing CF real-IP setup
    if grep -rqsE '^\s*real_ip_header' "$NGINX_CONFD"/ 2>/dev/null; then
        warn "Existing real_ip_header directive detected — toolkit's cloudflare-real-ip.conf will coexist (duplicate set_real_ip_from is harmless)."
    fi

    # Detect existing limit_req_zone whose names overlap with ours
    if grep -rqsE 'limit_req_zone.*zone=ddos_(req|auth|post|download)_limit' "$NGINX_CONFD"/ 2>/dev/null; then
        err "Found a previous toolkit install (zones ddos_*_limit already exist). Use rollback.sh first, then re-install."
        exit 3
    fi
}

# ---------------------------------------------------------------------------
# Top-of-script banner
# ---------------------------------------------------------------------------
section "DDoS Toolkit v3 install"
[[ $DRY_RUN -eq 1 ]] && warn "DRY-RUN — no changes will be written"
log "Source:   $SCRIPT_DIR"
log "Backup:   $BACKUP_DIR"
log "Manifest: $MANIFEST"

detect_environment

# ---------------------------------------------------------------------------
# Required dirs
# ---------------------------------------------------------------------------
section "Directories"
ddo "mkdir -p \"$NGINX_CONFD\" \"$NGINX_SNIP\" \"$BACKUP_DIR\""

# ---------------------------------------------------------------------------
# Nginx DDoS configs
# ---------------------------------------------------------------------------
section "Nginx DDoS configs"
install_file "$SCRIPT_DIR/config/nginx/conf.d/cloudflare-real-ip.conf" "$NGINX_CONFD/"
install_file "$SCRIPT_DIR/config/nginx/conf.d/ddos-global.conf"        "$NGINX_CONFD/"
install_file "$SCRIPT_DIR/config/nginx/snippets/ddos-global.conf"      "$NGINX_SNIP/"
install_file "$SCRIPT_DIR/config/nginx/snippets/ddos-auth.conf"        "$NGINX_SNIP/"
install_file "$SCRIPT_DIR/config/nginx/snippets/ddos-post.conf"        "$NGINX_SNIP/"
install_file "$SCRIPT_DIR/config/nginx/snippets/ddos-download.conf"    "$NGINX_SNIP/"
install_file "$SCRIPT_DIR/config/nginx/snippets/ddos-advanced.conf"    "$NGINX_SNIP/"

# ---------------------------------------------------------------------------
# Cache configs
# ---------------------------------------------------------------------------
section "Nginx cache configs"
if [[ $SKIP_CACHE -eq 1 ]]; then
    warn "skipped (--no-cache)"
else
    install_file "$SCRIPT_DIR/config/nginx/conf.d/cache-global.conf"      "$NGINX_CONFD/"
    install_file "$SCRIPT_DIR/config/nginx/snippets/cache-static.conf"    "$NGINX_SNIP/"
    install_file "$SCRIPT_DIR/config/nginx/snippets/cache-proxy.conf"     "$NGINX_SNIP/"
    install_file "$SCRIPT_DIR/config/nginx/snippets/cache-microcache.conf" "$NGINX_SNIP/"
    if [[ ! -d /var/cache/nginx/proxy ]]; then
        ddo "mkdir -p /var/cache/nginx/proxy /var/cache/nginx/proxy_temp"
        manifest_record_action "MKDIR:/var/cache/nginx/proxy"
        manifest_record_action "MKDIR:/var/cache/nginx/proxy_temp"
    fi
    ddo "chown -R www-data:www-data /var/cache/nginx" || true
fi

# ---------------------------------------------------------------------------
# Blocklist + whitelist (preserve manual edits)
# ---------------------------------------------------------------------------
section "Blocklist + whitelist"
if [[ ! -f "$NGINX_DIR/ddos-blocklist-generated.conf" ]]; then
    install_file "$SCRIPT_DIR/config/nginx/ddos-blocklist-generated.conf" "$NGINX_DIR/"
else
    hint "preserved: $NGINX_DIR/ddos-blocklist-generated.conf"
fi
if [[ ! -f "$NGINX_DIR/ddos-whitelist.conf" ]]; then
    install_file "$SCRIPT_DIR/config/nginx/ddos-whitelist.conf" "$NGINX_DIR/"
    warn "EDIT: $NGINX_DIR/ddos-whitelist.conf — add your office/monitoring IPs"
else
    hint "preserved: $NGINX_DIR/ddos-whitelist.conf"
fi
ddo "touch \"$NGINX_DIR/ddos-blocklist-meta.json\""
ddo "chmod 0644 \"$NGINX_DIR/ddos-blocklist-meta.json\""
[[ ! -e "$NGINX_DIR/ddos-blocklist-meta.json.before-toolkit" ]] && manifest_record_install "$NGINX_DIR/ddos-blocklist-meta.json"

# ---------------------------------------------------------------------------
# Scripts
# ---------------------------------------------------------------------------
section "Scripts → $SBIN"
install_file "$SCRIPT_DIR/scripts/ddos-nginx-autoblock.sh" "$SBIN/" 0755
install_file "$SCRIPT_DIR/scripts/ddos-behavior-engine.sh" "$SBIN/" 0755
install_file "$SCRIPT_DIR/scripts/update-cloudflare-ips.sh" "$SBIN/" 0755
install_file "$SCRIPT_DIR/scripts/cache-warmup.sh"         "$SBIN/" 0755
install_file "$SCRIPT_DIR/firewall/ufw-cloudflare-only.sh" "$SBIN/" 0755

# ---------------------------------------------------------------------------
# Cron
# ---------------------------------------------------------------------------
section "Cron"
if [[ $SKIP_CRON -eq 1 ]]; then
    warn "skipped (--no-cron)"
else
    install_file "$SCRIPT_DIR/config/cron/ddos-nginx-autoblock" /etc/cron.d/
    if [[ -f "$SBIN/ddos-behavior-engine.sh" || $DRY_RUN -eq 1 ]]; then
        if [[ $DRY_RUN -eq 0 ]]; then
            cat >/etc/cron.d/ddos-behavior-engine <<EOF
* * * * * root $SBIN/ddos-behavior-engine.sh >>/var/log/ddos-behavior-engine.log 2>&1
EOF
            chmod 0644 /etc/cron.d/ddos-behavior-engine
            manifest_record_install /etc/cron.d/ddos-behavior-engine
            log "  cron behavior-engine: every minute"
        else
            ddo "tee /etc/cron.d/ddos-behavior-engine"
        fi
    fi
fi

# ---------------------------------------------------------------------------
# Logrotate
# ---------------------------------------------------------------------------
section "Logrotate"
install_file "$SCRIPT_DIR/config/logrotate/ddos-toolkit" /etc/logrotate.d/

# ---------------------------------------------------------------------------
# Sysctl
# ---------------------------------------------------------------------------
section "Sysctl kernel hardening"
if [[ $SKIP_SYSCTL -eq 1 ]]; then
    warn "skipped (--no-sysctl)"
else
    install_file "$SCRIPT_DIR/config/sysctl/99-ddos-hardening.conf" /etc/sysctl.d/
    if [[ $DRY_RUN -eq 0 ]] && command -v sysctl >/dev/null; then
        if sysctl --system >/dev/null 2>&1; then
            log "  sysctl applied"
            manifest_record_action "SYSCTL_APPLIED:1"
        else
            warn "  sysctl reported errors (probably nf_conntrack module not loaded; not fatal)"
        fi
    fi
fi

# ---------------------------------------------------------------------------
# Fail2ban (gracefully no-op if not installed)
# ---------------------------------------------------------------------------
section "Fail2ban (optional)"
if [[ $SKIP_FAIL2BAN -eq 1 ]]; then
    warn "skipped (--no-fail2ban)"
elif ! command -v fail2ban-client >/dev/null 2>&1; then
    warn "fail2ban not installed — skipping. (apt install fail2ban; re-run installer)"
else
    install_file "$SCRIPT_DIR/fail2ban/jail.local" /etc/fail2ban/jail.d/ddos-toolkit.local
    install_file "$SCRIPT_DIR/fail2ban/filter.d/nginx-ddos.conf"     /etc/fail2ban/filter.d/
    install_file "$SCRIPT_DIR/fail2ban/filter.d/nginx-noscript.conf" /etc/fail2ban/filter.d/
    install_file "$SCRIPT_DIR/fail2ban/filter.d/nginx-badbots.conf"  /etc/fail2ban/filter.d/
    if [[ $DRY_RUN -eq 0 ]] && systemctl is-active fail2ban >/dev/null 2>&1; then
        ddo "systemctl reload fail2ban"
        manifest_record_action "FAIL2BAN_RELOADED:1"
    fi
fi

# ---------------------------------------------------------------------------
# UFW lockdown — opt-in only
# ---------------------------------------------------------------------------
section "UFW origin-lockdown"
if [[ $APPLY_UFW -eq 1 ]]; then
    if [[ $DRY_RUN -eq 0 ]]; then
        warn "Running UFW lockdown — make sure SSH still works after this completes."
        ddo "$SBIN/ufw-cloudflare-only.sh"
        manifest_record_action "UFW_RESET_AND_LOCKED:1"
    else
        ddo "$SBIN/ufw-cloudflare-only.sh  # would run"
    fi
else
    hint "ufw script installed at $SBIN/ufw-cloudflare-only.sh; run manually with --dry-run to preview."
fi

# ---------------------------------------------------------------------------
# Log files
# ---------------------------------------------------------------------------
section "Log files"
for log_file in /var/log/ddos-nginx-autoblock.log \
                /var/log/ddos-behavior-engine.log \
                /var/log/update-cloudflare-ips.log \
                /var/log/nginx/ddos-blocked.log; do
    if [[ ! -e "$log_file" ]]; then
        ddo "touch \"$log_file\""
        manifest_record_install "$log_file"
    fi
done

# ---------------------------------------------------------------------------
# Write the manifest now — rollback can use it even if nginx -t fails below.
# ---------------------------------------------------------------------------
manifest_finalize

# ---------------------------------------------------------------------------
# Validate + reload nginx — auto-rollback on failure
# ---------------------------------------------------------------------------
section "Validate nginx"
if [[ $DRY_RUN -eq 1 ]]; then
    ddo "nginx -t"
elif nginx -t 2>&1 | tee /tmp/.ddos-nginx-test; then
    log "nginx -t passed"
    if systemctl is-active nginx >/dev/null 2>&1; then
        ddo "systemctl reload nginx"
        log "nginx reloaded"
    else
        warn "nginx not running — start it: systemctl enable --now nginx"
    fi
else
    err "nginx -t FAILED. Auto-rolling back nginx pieces..."
    # Pull every file in the [INSTALLED] section back out
    sed -n '/^\[INSTALLED\]$/,/^\[/p' "$MANIFEST" | grep -E '^/etc/nginx|^/usr/local/sbin' | while read -r f; do
        [[ -f "$f" ]] && rm -f "$f" && warn "  removed $f"
    done
    # Restore everything in [OVERWRITTEN]
    sed -n '/^\[OVERWRITTEN\]$/,/^\[/p' "$MANIFEST" | grep -E '^/etc/nginx' | while IFS='|' read -r live backup; do
        [[ -f "$backup" ]] && cp -p "$backup" "$live" && warn "  restored $live"
    done
    err "Rolled back nginx pieces. See $MANIFEST and $BACKUP_DIR."
    err "Original nginx -t output: $(cat /tmp/.ddos-nginx-test)"
    exit 1
fi

# ---------------------------------------------------------------------------
# Done
# ---------------------------------------------------------------------------
echo
log "═════════════════════════════════════════════"
log " DDoS Toolkit v3 — install complete"
log "═════════════════════════════════════════════"
echo
echo "Manifest:  $MANIFEST"
echo "Backup:    $BACKUP_DIR"
echo "Rollback:  sudo $ROLLBACK_SCRIPT"
echo
echo "Next steps:"
echo "  1. Add your office/monitoring IPs to $NGINX_DIR/ddos-whitelist.conf"
echo "  2. Per-vhost in your server { } blocks:"
echo "       include snippets/ddos-global.conf;     # rate limits"
echo "       include snippets/ddos-advanced.conf;   # UA + query-string filters"
echo "       include snippets/cache-static.conf;    # if static-heavy"
echo "  3. Lock the origin to Cloudflare only (after confirming SSH works):"
echo "       sudo $SBIN/ufw-cloudflare-only.sh --dry-run    # preview"
echo "       sudo $SBIN/ufw-cloudflare-only.sh              # apply"
echo "  4. Cloudflare-side hardening:  cat $SCRIPT_DIR/docs/cloudflare-hardening.md"
echo
[[ $DRY_RUN -eq 1 ]] && warn "DRY-RUN: nothing was actually changed. Re-run without --dry-run to apply."
