#!/usr/bin/env bash
#
# DDoS Toolkit v3 — rollback
#
# Reverses an install. By default rolls back the MOST RECENT manifest in
# /etc/nginx/ddos-toolkit-manifest-*.txt — removes any files install.sh added,
# restores any files install.sh overwrote (from /etc/nginx/ddos-backup-<ts>/),
# and reloads nginx, fail2ban, sysctl as needed.
#
# USAGE
#   sudo ./rollback.sh                 roll back the most recent install
#   sudo ./rollback.sh --list          show every install manifest on this server
#   sudo ./rollback.sh <manifest>      roll back a specific install (use full path)
#   sudo ./rollback.sh --dry-run       preview the reversal, change nothing
#
# WHAT IT REVERSES
#   files added by install.sh   →  removed
#   files install.sh overwrote  →  restored from BACKUP_DIR
#   sysctl                      →  /etc/sysctl.d/* re-applied via `sysctl --system`
#   cron / logrotate / fail2ban →  file removed; fail2ban reloaded if active
#   UFW lockdown                →  cannot 100% reverse (UFW was --force reset).
#                                  Best effort; rebuild your rules manually.
#
# RELATED
#   sudo ./install.sh                  apply (creates the manifest this reads)
#   sudo ./configure.sh                set webhook + thresholds
#
set -euo pipefail

RED=$'\033[0;31m'
GREEN=$'\033[0;32m'
YELLOW=$'\033[1;33m'
CYAN=$'\033[0;36m'
GRAY=$'\033[0;90m'
NC=$'\033[0m'

DRY_RUN=0
DO_LIST=0
TARGET=""

while [[ $# -gt 0 ]]; do
    case "$1" in
        --dry-run) DRY_RUN=1; shift ;;
        --list)    DO_LIST=1; shift ;;
        -h|--help) awk 'NR==1{next} /^[^#]/{exit} {sub(/^# ?/,"  "); print}' "$0"; exit 0 ;;
        *)         TARGET="$1"; shift ;;
    esac
done

log()      { printf "%s[+]%s %s\n" "$GREEN"  "$NC" "$*"; }
warn()     { printf "%s[!]%s %s\n" "$YELLOW" "$NC" "$*"; }
err()      { printf "%s[✗]%s %s\n" "$RED"    "$NC" "$*" >&2; }
section()  { printf "\n%s═══ %s%s\n" "$CYAN" "$*" "$NC"; }
hint()     { printf "%s    %s%s\n" "$GRAY"   "$*" "$NC"; }

[[ $EUID -eq 0 ]] || { err "Run as root (sudo $0)"; exit 1; }

ddo() {
    if [[ $DRY_RUN -eq 1 ]]; then
        printf "  ${YELLOW}DRY${NC}  %s\n" "$*"
    else
        printf "  ${GREEN}RUN${NC}  %s\n" "$*"
        eval "$@"
    fi
}

# ---------------------------------------------------------------------------
# --list mode
# ---------------------------------------------------------------------------
if [[ $DO_LIST -eq 1 ]]; then
    section "Available manifests (most recent first)"
    found=0
    while IFS= read -r m; do
        ts=$(grep -oE '^INSTALL_TIMESTAMP=.*' "$m" | head -1 | cut -d= -f2)
        installed_count=$(sed -n '/^\[INSTALLED\]$/,/^\[/p' "$m" | grep -cE '^/' || true)
        overwrote_count=$(sed -n '/^\[OVERWRITTEN\]$/,/^\[/p' "$m" | grep -cE '^/' || true)
        printf "  %s\n      timestamp: %s · added=%s · replaced=%s\n" "$m" "$ts" "$installed_count" "$overwrote_count"
        found=1
    done < <(ls -1t /etc/nginx/ddos-toolkit-manifest-*.txt 2>/dev/null)
    [[ $found -eq 0 ]] && warn "No manifests found in /etc/nginx/."
    exit 0
fi

# ---------------------------------------------------------------------------
# Resolve target manifest
# ---------------------------------------------------------------------------
if [[ -z "$TARGET" ]]; then
    TARGET=$(ls -1t /etc/nginx/ddos-toolkit-manifest-*.txt 2>/dev/null | head -1)
    if [[ -z "$TARGET" ]]; then
        err "No install manifest found in /etc/nginx/. Nothing to roll back."
        err "If you have a backup dir (e.g. /etc/nginx/ddos-backup-*), restore it manually."
        exit 1
    fi
fi
[[ -f "$TARGET" ]] || { err "Manifest not found: $TARGET"; exit 1; }

section "Rollback plan"
log "Manifest: $TARGET"
log "Created:  $(grep -oE '^INSTALL_TIMESTAMP=.*' "$TARGET" | head -1 | cut -d= -f2)"
backup_dir=$(grep -oE '^BACKUP_DIR=.*' "$TARGET" | head -1 | cut -d= -f2)
log "Backup:   $backup_dir"
[[ $DRY_RUN -eq 1 ]] && warn "DRY-RUN — nothing will actually change"

# ---------------------------------------------------------------------------
# 1. Remove files that this install added (the [INSTALLED] section)
# ---------------------------------------------------------------------------
section "1/4  Remove added files"
removed=0 missing=0
while IFS= read -r f; do
    [[ -z "$f" ]] && continue
    [[ "$f" == \[* ]] && continue
    [[ "$f" == \#* ]] && continue
    if [[ -f "$f" ]]; then
        ddo "rm -f \"$f\""
        removed=$((removed+1))
    else
        hint "already gone: $f"
        missing=$((missing+1))
    fi
done < <(sed -n '/^\[INSTALLED\]$/,/^\[/p' "$TARGET" | sed '1d;$d')
log "removed=$removed  already_gone=$missing"

# ---------------------------------------------------------------------------
# 2. Restore overwritten files from the backup dir
# ---------------------------------------------------------------------------
section "2/4  Restore overwritten files"
restored=0 lost=0
while IFS='|' read -r live backup; do
    [[ -z "$live" || -z "$backup" ]] && continue
    [[ "$live" == \[* ]] && continue
    [[ "$live" == \#* ]] && continue
    if [[ -f "$backup" ]]; then
        ddo "cp -p \"$backup\" \"$live\""
        restored=$((restored+1))
    else
        warn "backup gone, cannot restore: $live  (was $backup)"
        lost=$((lost+1))
    fi
done < <(sed -n '/^\[OVERWRITTEN\]$/,/^\[/p' "$TARGET" | sed '1d;$d')
log "restored=$restored  unrecoverable=$lost"

# ---------------------------------------------------------------------------
# 3. Reverse non-file actions
# ---------------------------------------------------------------------------
section "3/4  Reverse side-effects"
fail2ban_reload=0
sysctl_apply=0
ufw_was_reset=0
while IFS= read -r action; do
    [[ -z "$action" ]] && continue
    [[ "$action" == \[* ]] && continue
    [[ "$action" == \#* ]] && continue
    case "$action" in
        FAIL2BAN_RELOADED:1)   fail2ban_reload=1 ;;
        SYSCTL_APPLIED:1)      sysctl_apply=1 ;;
        UFW_RESET_AND_LOCKED:1) ufw_was_reset=1 ;;
        MKDIR:*)
            d="${action#MKDIR:}"
            if [[ -d "$d" && -z "$(ls -A "$d" 2>/dev/null)" ]]; then
                ddo "rmdir \"$d\""
            fi
            ;;
    esac
done < <(sed -n '/^\[ACTIONS\]$/,/^\[/p' "$TARGET" | sed '1d;$d')

if [[ $sysctl_apply -eq 1 ]]; then
    ddo "sysctl --system"
    hint "  (re-applies all /etc/sysctl.d/*.conf — values not defined elsewhere reset to kernel defaults)"
fi
if [[ $fail2ban_reload -eq 1 ]] && command -v fail2ban-client >/dev/null 2>&1; then
    if systemctl is-active fail2ban >/dev/null 2>&1; then
        ddo "systemctl reload fail2ban"
    fi
fi
if [[ $ufw_was_reset -eq 1 ]]; then
    warn "UFW was --force reset by install.sh. Rollback can't restore your old UFW rules."
    warn "Run 'ufw status numbered' to inspect; 'ufw disable' to turn off; rebuild rules manually."
fi

# ---------------------------------------------------------------------------
# 4. Validate + reload nginx
# ---------------------------------------------------------------------------
section "4/4  Validate nginx"
if [[ $DRY_RUN -eq 1 ]]; then
    ddo "nginx -t"
    warn "DRY-RUN — no validation actually run"
else
    if nginx -t 2>&1 | tee /tmp/.ddos-nginx-rollback; then
        log "nginx -t passed"
        if systemctl is-active nginx >/dev/null 2>&1; then
            ddo "systemctl reload nginx"
        fi
    else
        err "nginx -t FAILED after rollback. The previous state had a config error too,"
        err "or rollback removed something that another vhost still includes."
        err "Inspect: cat /tmp/.ddos-nginx-rollback"
        exit 1
    fi
fi

# ---------------------------------------------------------------------------
# Mark this manifest as rolled-back so future rollbacks skip it
# ---------------------------------------------------------------------------
if [[ $DRY_RUN -eq 0 ]]; then
    rolled_back_path="${TARGET%.txt}.rolled-back-$(date +%Y%m%d-%H%M%S).txt"
    mv "$TARGET" "$rolled_back_path"
    log "Manifest renamed → $rolled_back_path"
fi

echo
log "═════════════════════════════════════════════"
log " Rollback complete"
log "═════════════════════════════════════════════"
echo
hint "If something looks wrong, the backup dir is preserved at:"
hint "    $backup_dir"
hint "Restore individual files manually with: cp /path/from/backup /etc/nginx/..."
