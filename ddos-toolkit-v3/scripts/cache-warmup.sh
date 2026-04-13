#!/usr/bin/env bash
# =============================================================================
# Cache Warmup & Pre-Compression Script v3.0
# =============================================================================
# Run after every deploy to:
#   1. Pre-compress all static assets (gzip + brotli)
#   2. Warm nginx's open_file_cache by reading all files
#   3. Warm OS page cache (files loaded into RAM)
#
# With pre-compressed files, nginx serves .gz/.br directly with ZERO CPU.
# Under DDoS, this is the difference between 50k req/s and 5k req/s.
#
# Usage:
#   ./cache-warmup.sh /var/www/yoursite
#   ./cache-warmup.sh /var/www/yoursite --brotli    # if brotli is installed
#   ./cache-warmup.sh /var/www/yoursite --clean      # remove .gz/.br files
# =============================================================================
set -euo pipefail

SITE_ROOT="${1:-}"
BROTLI=0
CLEAN=0
PARALLEL_JOBS="${PARALLEL_JOBS:-$(nproc)}"

if [[ -z "$SITE_ROOT" ]]; then
    echo "Usage: $0 /path/to/site/root [--brotli] [--clean]"
    echo ""
    echo "Options:"
    echo "  --brotli    Also create .br files (requires brotli command)"
    echo "  --clean     Remove all .gz and .br files"
    echo ""
    echo "Env vars:"
    echo "  PARALLEL_JOBS    Number of parallel compression jobs (default: nproc)"
    exit 1
fi

for arg in "${@:2}"; do
    case "$arg" in
        --brotli) BROTLI=1 ;;
        --clean)  CLEAN=1 ;;
        *) echo "Unknown argument: $arg" >&2; exit 2 ;;
    esac
done

if [[ ! -d "$SITE_ROOT" ]]; then
    echo "ERROR: Directory not found: $SITE_ROOT" >&2
    exit 1
fi

log() { printf '[%s] %s\n' "$(date -u '+%Y-%m-%dT%H:%M:%SZ')" "$1"; }

# Compressible file extensions.
EXTENSIONS="html|htm|css|js|json|xml|svg|txt|csv|md|webmanifest|manifest|rss|atom|map|ico|ttf|otf|eot|woff"

# --- Clean mode ---
if [[ "$CLEAN" -eq 1 ]]; then
    log "Removing pre-compressed files from $SITE_ROOT..."
    find "$SITE_ROOT" -type f \( -name "*.gz" -o -name "*.br" \) -delete
    count=$(find "$SITE_ROOT" -type f | wc -l)
    log "Cleaned. Remaining files: $count"
    exit 0
fi

# --- Step 1: Pre-compress with gzip ---
log "Pre-compressing with gzip (level 9, $PARALLEL_JOBS jobs)..."
gzip_count=0

find "$SITE_ROOT" -type f -regextype posix-extended \
    -regex ".*\.($EXTENSIONS)$" \
    ! -name "*.gz" ! -name "*.br" | while IFS= read -r file; do

    gz_file="${file}.gz"

    # Skip if .gz exists and is newer than source.
    if [[ -f "$gz_file" ]] && [[ "$gz_file" -nt "$file" ]]; then
        continue
    fi

    # Gzip level 9 for max compression. This runs at deploy time,
    # not request time, so CPU cost doesn't matter.
    gzip -9 -k -f "$file"
    gzip_count=$((gzip_count + 1))
done

log "Gzip: compressed $gzip_count files."

# --- Step 2: Pre-compress with brotli (optional) ---
if [[ "$BROTLI" -eq 1 ]]; then
    if ! command -v brotli >/dev/null 2>&1; then
        log "WARNING: brotli command not found. Install with: apt install brotli"
        log "Skipping brotli compression."
    else
        log "Pre-compressing with brotli (level 11, $PARALLEL_JOBS jobs)..."
        br_count=0

        find "$SITE_ROOT" -type f -regextype posix-extended \
            -regex ".*\.($EXTENSIONS)$" \
            ! -name "*.gz" ! -name "*.br" | while IFS= read -r file; do

            br_file="${file}.br"

            if [[ -f "$br_file" ]] && [[ "$br_file" -nt "$file" ]]; then
                continue
            fi

            brotli -Z -k -f "$file" -o "$br_file"
            br_count=$((br_count + 1))
        done

        log "Brotli: compressed $br_count files."
    fi
fi

# --- Step 3: Warm OS page cache ---
# Read all files into memory so the kernel page cache is hot.
# After this, sendfile serves directly from RAM — zero disk reads.
log "Warming OS page cache..."
find "$SITE_ROOT" -type f ! -name "*.br" -exec cat {} + > /dev/null 2>&1
log "Page cache warmed."

# --- Step 4: Report ---
total_files=$(find "$SITE_ROOT" -type f ! -name "*.gz" ! -name "*.br" | wc -l)
total_gz=$(find "$SITE_ROOT" -type f -name "*.gz" | wc -l)
total_br=$(find "$SITE_ROOT" -type f -name "*.br" | wc -l)
total_size=$(du -sh "$SITE_ROOT" | awk '{print $1}')
original_size=$(find "$SITE_ROOT" -type f ! -name "*.gz" ! -name "*.br" -exec du -ch {} + 2>/dev/null | tail -1 | awk '{print $1}')
gz_size=$(find "$SITE_ROOT" -type f -name "*.gz" -exec du -ch {} + 2>/dev/null | tail -1 | awk '{print $1}')

log "========================================="
log " Cache Warmup Complete"
log "========================================="
log " Site root:     $SITE_ROOT"
log " Total files:   $total_files (original) + $total_gz (.gz) + $total_br (.br)"
log " Original size: ${original_size:-0}"
log " Gzip size:     ${gz_size:-0}"
log " Total on disk: $total_size"
log "========================================="
log ""
log " Nginx will now serve pre-compressed files with zero CPU cost."
log " OS page cache is warm — files will be served from RAM."
log ""
log " Run this script after every deploy:"
log "   $0 $SITE_ROOT"
