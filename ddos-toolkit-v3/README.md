# 🛡️ DDoS Prevention Toolkit v3 (Nginx + Ubuntu)

Multi-layer DDoS prevention: **origin firewall lockdown, kernel hardening, rate limiting, behavioral pattern detection, request-shape filtering, IP-level fail2ban bans, adaptive auto-blocking, and Cloudflare-side hardening guidance.**

---

## 🚀 Three commands. That's it.

Everything you do with this toolkit is one of three scripts at the project root:

```
ddos-toolkit-v3/
├── install.sh       ← apply  the toolkit
├── rollback.sh      ← reverse it
└── configure.sh     ← set the alert webhook + thresholds
```

Each has a working `--help`. None of them need flags for the common case.

### `install.sh` — apply the toolkit

```bash
sudo ./install.sh --dry-run         # preview every change first (recommended)
sudo ./install.sh                   # apply with safe defaults
sudo ./install.sh --apply-ufw       # also lock origin to Cloudflare IPs (destructive)
sudo ./install.sh --help            # full reference
```

Re-runs are idempotent. Every overwritten file is backed up, every action is logged in a manifest at `/etc/nginx/ddos-toolkit-manifest-<ts>.txt`. If `nginx -t` fails after install, the script auto-rolls-back via `rollback.sh`. Opt-out flags: `--no-sysctl`, `--no-fail2ban`, `--no-ufw`, `--no-cron`, `--no-cache`.

### `rollback.sh` — reverse any install

```bash
sudo ./rollback.sh                  # reverse the most recent install
sudo ./rollback.sh --list           # show every install on this server
sudo ./rollback.sh <manifest-path>  # reverse a specific install
sudo ./rollback.sh --dry-run        # preview the reversal
sudo ./rollback.sh --help           # full reference
```

Reads the manifest, removes added files, restores backed-up files in place, reloads nginx + fail2ban + sysctl. Backup dir is preserved as audit trail.

### `configure.sh` — alert webhook + thresholds

```bash
sudo ./configure.sh                                 # interactive prompts
sudo ./configure.sh --discord-webhook https://discord.com/api/webhooks/<id>/<token>
sudo ./configure.sh --slack-webhook   https://hooks.slack.com/services/<T>/<B>/<X>
sudo ./configure.sh --test                          # POST a real test alert
sudo ./configure.sh --show                          # current config (URL masked)
sudo ./configure.sh --set REQUESTS_THRESHOLD=50     # any single key
sudo ./configure.sh --help                          # full reference
```

Writes `/etc/default/ddos-toolkit`. The cron'd behavior engine re-sources this file every minute — no service restart needed. Where to get the URL:

- **Discord:** channel → ⚙ Edit Channel → Integrations → Webhooks → New Webhook → Copy URL
- **Slack:** [api.slack.com](https://api.slack.com) → Your Apps → pick app → Incoming Webhooks → Add Webhook → Copy URL

---

## Defense layers (Cloudflare → kernel)

| # | Layer | What it stops | Where |
|---|---|---|---|
| 0 | **Cloudflare edge** | L3/L4 floods, bot ASNs, edge cache absorbs identical reads | [docs/cloudflare-hardening.md](docs/cloudflare-hardening.md) |
| 1 | **UFW lockdown** | Direct-IP probes that bypass Cloudflare | [firewall/ufw-cloudflare-only.sh](firewall/ufw-cloudflare-only.sh) |
| 2 | **Kernel sysctl** | SYN floods, conntrack exhaustion, ephemeral port starvation | [config/sysctl/99-ddos-hardening.conf](config/sysctl/99-ddos-hardening.conf) |
| 3 | **Nginx rate limits** | Per-IP request rate, concurrent connections | [config/nginx/conf.d/ddos-global.conf](config/nginx/conf.d/ddos-global.conf) |
| 4 | **Nginx request-shape** | Empty UA, scanner UAs, SQLi/XSS query strings, slowloris | [config/nginx/snippets/ddos-advanced.conf](config/nginx/snippets/ddos-advanced.conf) |
| 5 | **Adaptive blocklist** | High-rate, all-4xx, prior-444 IPs (cron every minute) | [scripts/ddos-behavior-engine.sh](scripts/ddos-behavior-engine.sh) |
| 6 | **fail2ban** | Repeat offenders banned at the firewall (TCP-level) | [fail2ban/jail.local](fail2ban/jail.local) |
| 7 | **Microcache + edge** | Absorb identical reads at near-zero cost | [config/nginx/snippets/cache-microcache.conf](config/nginx/snippets/cache-microcache.conf) |

Layers stack — each is independently useful, and an attacker has to defeat all of them to reach your application.

---

## Original feature matrix below

## ✅ What It Blocks

| Layer | What | How |
|-------|------|-----|
| **Kernel** | SYN floods, ICMP floods, IP spoofing, conntrack exhaustion | sysctl hardening |
| Rate limit | Request floods | `limit_req` 15 req/s per IP |
| Conn limit | Connection floods / slowloris | `limit_conn` 50/IP + 10k/server |
| Buffer limit | Large header attacks / buffer overflow | `client_header_buffer_size` 1k, 4×8k |
| HTTP/2 | Stream flood / rapid-reset | `http2_max_concurrent_streams` 64 |
| Query flood | `/?abc=RANDOM` patterns | Regex map → 444 |
| Path scanner | `/wp-login.php`, `/.env`, `/.aws/`, `/actuator`, `.bak`, etc. | Regex map → 444 |
| Bad UA | `python-requests`, `curl`, `sqlmap`, `GPTBot`, 60+ patterns | Map → 444 |
| Bad referer | `semalt.com`, `darodar.com`, etc. | Map → 444 |
| Bad method | TRACE, TRACK, CONNECT | Map → 444 |
| HTTP smuggle | Malformed `Transfer-Encoding` | Map → 444 |
| IP blocklist | Known bad IPs + auto-detected | `geo` block → 444 |
| POST flood | Excessive POST from single IP | Auto-block script |
| 4xx hammer | Excessive 4xx from single IP | Auto-block script |
| High freq | Any IP > 200 hits/scan window | Auto-block script |
| Subnet agg | ≥10 IPv4 from same /24, ≥5 IPv6 from same /48 | Auto-block |
| Download abuse | Bandwidth saturation | `limit_rate` 1MB/s per conn |
| Timeouts | Slowloris / slow-read / slow-post | 10s body/header/send |
| **Caching** | | |
| Open file cache | Eliminate disk syscalls | `open_file_cache` 50k FDs in RAM |
| Gzip static | Zero-CPU compression | Pre-compressed `.gz` files |
| Brotli static | Better compression, zero CPU | Pre-compressed `.br` files |
| Browser cache | Eliminate repeat requests | `Cache-Control` + `immutable` |
| Stale-while-revalidate | Instant response during refresh | Background revalidation |
| Proxy cache | Backend down? Serve stale | `proxy_cache_use_stale` |
| Micro-cache | 10k req/s → 1 backend hit | 1-second cache for dynamic |
| RAM cache (tmpfs) | Zero disk I/O for proxy cache | tmpfs mount |
| Page cache warmup | Hot RAM on deploy | `cache-warmup.sh` script |

### v3.0 Improvements over v2

- **Kernel sysctl hardening** — SYN cookies, conntrack tuning, ICMP rate limits, IP spoofing protection
- **Blocklist TTL** — auto-purge entries older than N days (default: 7)
- **Blocklist size cap** — hard limit prevents runaway growth (default: 50k entries)
- **IPv6 /48 subnet aggregation** — was IPv4-only
- **Proper CIDR whitelist matching** — v2 only did exact string match (broken)
- **HTTP smuggling detection** — malformed Transfer-Encoding blocked
- **Referer spam blocking**
- **Download/bandwidth abuse protection** — per-connection rate limiting
- **Full security headers** — Permissions-Policy, X-XSS-Protection, HSTS (opt-in)
- **Request buffer size limits** — anti large-header attacks
- **HTTP/2 stream abuse protection**
- **Separate blocked request log** — JSON format for easy audit
- **Webhook/email alerting** — notifies when attack threshold is hit
- **Log rotation** — all DDoS logs auto-rotate
- **Automated install/uninstall script**
- **Updated scanner patterns** — Spring Boot, K8s, Docker, Node.js paths, backup extensions
- **Updated bad UA list** — 60+ patterns including AI crawlers
- **OPTIONS no longer blocked** — CORS-safe by default, configurable
- **Cloudflare updater** — retry logic, checksum validation, backup rotation

#### Cache Hardening (new in v3)
- **Open file cache** — 50k file descriptors cached in RAM, zero disk syscalls
- **Zero-copy serving** — `sendfile` + `tcp_nopush` for kernel-direct file delivery
- **Pre-compression** — `gzip_static` + `brotli_static` serve pre-compressed files with zero CPU
- **Aggressive browser caching** — `immutable` for hashed assets, `stale-while-revalidate` for HTML
- **Proxy cache with stale serving** — backend goes down, users still get content
- **Micro-cache** — 1-second cache turns 10k DDoS req/s into 1 backend hit
- **RAM-backed proxy cache** — tmpfs mount eliminates all cache disk I/O
- **Cache warmup script** — pre-compresses assets + warms OS page cache on deploy
- **Page cache kernel tuning** — `vm.swappiness=10` keeps file pages hot in RAM
- **Example vhost configs** — copy-paste ready for static sites and reverse proxies

## ✅ Quick Install

```bash
git clone https://github.com/josuamarcelc/nginx-anti-ddos-attack.git
cd nginx-anti-ddos-attack/ddos-toolkit-v3
sudo ./install.sh
```

### Manual Install

```bash
# Nginx DDoS configs
cp config/nginx/conf.d/cloudflare-real-ip.conf /etc/nginx/conf.d/
cp config/nginx/conf.d/ddos-global.conf        /etc/nginx/conf.d/
cp config/nginx/snippets/ddos-global.conf       /etc/nginx/snippets/
cp config/nginx/snippets/ddos-auth.conf         /etc/nginx/snippets/
cp config/nginx/snippets/ddos-post.conf         /etc/nginx/snippets/
cp config/nginx/snippets/ddos-download.conf     /etc/nginx/snippets/

# Nginx cache configs
cp config/nginx/conf.d/cache-global.conf        /etc/nginx/conf.d/
cp config/nginx/snippets/cache-static.conf      /etc/nginx/snippets/
cp config/nginx/snippets/cache-proxy.conf       /etc/nginx/snippets/
cp config/nginx/snippets/cache-microcache.conf  /etc/nginx/snippets/
mkdir -p /var/cache/nginx/proxy /var/cache/nginx/proxy_temp
chown -R www-data:www-data /var/cache/nginx

# Blocklist + whitelist
cp config/nginx/ddos-blocklist-generated.conf   /etc/nginx/
cp config/nginx/ddos-whitelist.conf             /etc/nginx/

# Scripts
cp scripts/ddos-nginx-autoblock.sh              /usr/local/sbin/
cp scripts/update-cloudflare-ips.sh             /usr/local/sbin/
cp scripts/cache-warmup.sh                      /usr/local/sbin/
chmod +x /usr/local/sbin/ddos-nginx-autoblock.sh
chmod +x /usr/local/sbin/update-cloudflare-ips.sh
chmod +x /usr/local/sbin/cache-warmup.sh

# Cron + logrotate
cp config/cron/ddos-nginx-autoblock             /etc/cron.d/
cp config/logrotate/ddos-toolkit                /etc/logrotate.d/

# Kernel hardening
cp config/sysctl/99-ddos-hardening.conf         /etc/sysctl.d/
sysctl --system
```

### Edit your whitelist

```bash
nano /etc/nginx/ddos-whitelist.conf
# Add your server IP, monitoring IPs, office IPs
# CIDR notation is now properly supported: 198.51.100.0/24
```

### Enable in all vhosts

Inside each `server { }` block:

```nginx
include snippets/ddos-global.conf;
```

For login/admin endpoints:

```nginx
location /login {
    include snippets/ddos-auth.conf;
    # ... your config
}
```

For POST-heavy API endpoints:

```nginx
location /api {
    include snippets/ddos-post.conf;
    # ... your config
}
```

For large file downloads:

```nginx
location /downloads {
    include snippets/ddos-download.conf;
    # ... your config
}
```

### Test and reload

```bash
nginx -t
systemctl reload nginx
/usr/local/sbin/ddos-nginx-autoblock.sh --dry-run --verbose
```

## 🗄️ Cache Hardening (Static Site DDoS Survival)

The goal: your server survives a DDoS **without relying on Cloudflare**. Every request costs zero disk I/O and near-zero CPU because everything is served from RAM.

### How it works under DDoS

```
Attack traffic → DDoS filters (444, zero response body, costs nothing)
                 ↓ (passes filter)
Legit traffic  → open_file_cache (file descriptor in RAM, no stat() syscall)
                 → sendfile (zero-copy kernel→socket, no userspace)
                 → gzip_static (pre-compressed .gz on disk, no CPU)
                 → Browser cache (returning users: zero requests)
```

Result: 50,000+ req/s served from a single nginx instance with barely any CPU usage.

### Enable for static sites

In each static site `server { }` block:

```nginx
server {
    include snippets/ddos-global.conf;     # DDoS protection
    include snippets/cache-static.conf;    # Cache hardening
    root /var/www/yoursite;
}
```

### Pre-compress your assets (critical)

```bash
# After every deploy, run:
cache-warmup.sh /var/www/yoursite

# With brotli support:
cache-warmup.sh /var/www/yoursite --brotli

# Clean pre-compressed files:
cache-warmup.sh /var/www/yoursite --clean
```

This creates `.gz` (and optionally `.br`) copies of every compressible file. Nginx serves these directly via `gzip_static on` — **zero CPU per request**.

### Mount proxy cache on RAM (optional, for backend sites)

```bash
# Add to /etc/fstab:
echo 'tmpfs /var/cache/nginx tmpfs defaults,size=512m,mode=0755,uid=www-data,gid=www-data 0 0' >> /etc/fstab
mkdir -p /var/cache/nginx
mount /var/cache/nginx
```

### Cache snippets available

| Snippet | Use case |
|---------|----------|
| `cache-static.conf` | Pure static sites (HTML/CSS/JS/images) |
| `cache-proxy.conf` | Reverse proxy with backend (Node/PHP/Python) |
| `cache-microcache.conf` | Dynamic sites — 1-second cache, extreme DDoS resilience |

### Micro-cache: the secret weapon for dynamic sites

Even if your site is dynamic, caching responses for just **1 second** means:
- Normal traffic (100 req/s): backend handles 1 req/s, cache handles 99
- DDoS (10,000 req/s): backend handles 1 req/s, cache handles 9,999
- Content is at most 1 second stale — virtually invisible to users

```nginx
location / {
    proxy_pass http://backend;
    include snippets/cache-microcache.conf;
}
```

See `config/nginx/examples/static-site.conf` for a complete vhost example.

## ⚙️ How It Works

1. **Kernel layer** — sysctl settings handle SYN floods, ICMP abuse, IP spoofing, and connection table exhaustion before traffic reaches nginx.
2. **Nginx layer** — rate limits, connection limits, buffer limits, pattern maps, and geo blocks drop bad traffic immediately with `444` (no response body, saves bandwidth). Blocked requests log separately to `/var/log/nginx/ddos-blocked.log` in JSON.
3. **Auto-block script** — runs every 5 minutes via cron, scans the last 50k log lines for 5 attack patterns, auto-aggregates IPv4 /24 and IPv6 /48 subnets.
4. **TTL purge** — daily cron purges blocklist entries older than `BLOCK_TTL_DAYS` (default: 7).
5. **Alerting** — when new blocks exceed `ALERT_THRESHOLD` (default: 50), sends webhook/email notification.
6. **Whitelist** — IPs/CIDRs in `/etc/nginx/ddos-whitelist.conf` are never auto-blocked (proper CIDR matching).
7. **Cloudflare updater** — `update-cloudflare-ips.sh` fetches latest CF ranges weekly with retry and validation.

### Cron setup

```cron
# Auto-blocker: every 5 minutes
*/5 * * * * root SCAN_LINES=50000 /usr/local/sbin/ddos-nginx-autoblock.sh >>/var/log/ddos-nginx-autoblock.log 2>&1

# TTL purge: daily 4am
0 4 * * * root /usr/local/sbin/ddos-nginx-autoblock.sh --purge >>/var/log/ddos-nginx-autoblock.log 2>&1

# Cloudflare IP updater: weekly Sunday 3am
0 3 * * 0 root /usr/local/sbin/update-cloudflare-ips.sh >>/var/log/update-cloudflare-ips.log 2>&1
```

### Enable alerting

Add to your cron environment or `/etc/default/ddos-nginx-autoblock`:

```bash
# Slack/Discord/PagerDuty webhook
ALERT_WEBHOOK_URL="https://hooks.slack.com/services/YOUR/WEBHOOK/URL"

# Email (requires mailutils)
ALERT_EMAIL="ops@example.com"

# Alert when more than N new blocks in a single run
ALERT_THRESHOLD=50
```

## 🔧 Tuning

| Variable | Default | Description |
|----------|---------|-------------|
| `SCAN_LINES` | 50000 | Log lines to scan per run |
| `MIN_HITS` | 15 | Pattern hits to trigger block |
| `MIN_HITS_4XX` | 50 | 4xx responses to trigger block |
| `MIN_HITS_FREQ` | 200 | Total hits frequency cap |
| `MAX_NEW_IPS` | 5000 | Max new IPs per run |
| `SUBNET_MIN_IPS` | 10 | IPv4 IPs to auto-aggregate /24 |
| `SUBNET_MIN_IPS_V6` | 5 | IPv6 IPs to auto-aggregate /48 |
| `BLOCK_TTL_DAYS` | 7 | Days before auto-purge |
| `MAX_BLOCKLIST_ENTRIES` | 50000 | Hard cap on blocklist size |
| `ALERT_THRESHOLD` | 50 | New blocks to trigger alert |

### Security headers (opt-in)

Uncomment in `snippets/ddos-global.conf`:

```nginx
# HSTS — ONLY if you're 100% HTTPS
add_header Strict-Transport-Security "max-age=63072000; includeSubDomains; preload" always;

# CSP — tune per your application
add_header Content-Security-Policy "default-src 'self'; ..." always;
```

## 🔍 Quick Check

```bash
# Verify nginx config
nginx -t

# Check recent status codes
tail -n 5000 /var/log/nginx/access.log | awk '{print $9}' | sort | uniq -c | sort -nr | head -20

# Check auto-blocker log
tail -n 50 /var/log/ddos-nginx-autoblock.log

# Check blocked requests (JSON log)
tail -n 20 /var/log/nginx/ddos-blocked.log | jq .

# Dry run
/usr/local/sbin/ddos-nginx-autoblock.sh --dry-run --verbose

# Purge expired entries manually
/usr/local/sbin/ddos-nginx-autoblock.sh --purge --verbose

# Count blocked IPs
wc -l /etc/nginx/ddos-blocklist-generated.conf

# Check rate limit rejections
grep ' 429 ' /var/log/nginx/access.log | wc -l
```

## 🗑️ Uninstall

```bash
sudo ./install.sh --uninstall
nginx -t && systemctl reload nginx
sysctl --system
```

## 📁 File Structure

```
ddos-toolkit-v3/
├── install.sh                              # Automated installer
├── config/
│   ├── nginx/
│   │   ├── conf.d/
│   │   │   ├── cloudflare-real-ip.conf     # CF IP ranges (auto-updated)
│   │   │   ├── ddos-global.conf            # http{} DDoS: zones, maps, geo
│   │   │   └── cache-global.conf           # http{} Cache: open_file_cache, gzip, proxy_cache
│   │   ├── snippets/
│   │   │   ├── ddos-global.conf            # server{} DDoS: all protections
│   │   │   ├── ddos-auth.conf              # login/admin rate limiting
│   │   │   ├── ddos-post.conf              # POST endpoint rate limiting
│   │   │   ├── ddos-download.conf          # download bandwidth limiting
│   │   │   ├── cache-static.conf           # server{} Cache: static site headers
│   │   │   ├── cache-proxy.conf            # server{} Cache: reverse proxy + stale
│   │   │   └── cache-microcache.conf       # server{} Cache: 1-sec dynamic cache
│   │   ├── examples/
│   │   │   └── static-site.conf            # Complete vhost example
│   │   ├── ddos-blocklist-generated.conf   # auto-managed blocklist
│   │   └── ddos-whitelist.conf             # never-block list (CIDR supported)
│   ├── cron/
│   │   └── ddos-nginx-autoblock            # cron jobs
│   ├── logrotate/
│   │   └── ddos-toolkit                    # log rotation config
│   ├── sysctl/
│   │   └── 99-ddos-hardening.conf          # kernel network + page cache hardening
│   └── tmpfs/
│       └── cache-tmpfs.fstab               # RAM-backed cache mount config
└── scripts/
    ├── ddos-nginx-autoblock.sh             # auto-detection + blocking engine
    ├── update-cloudflare-ips.sh            # CF IP range updater
    └── cache-warmup.sh                     # pre-compress assets + warm page cache
```

## 💛 Support This Project

If this helped you, you can support here:

[![PayPal](https://img.shields.io/badge/PayPal-Donate-00457C?logo=paypal&logoColor=white)](https://www.paypal.me/josuamarcelc/1)
[![Buy Me a Coffee](https://img.shields.io/badge/Buy%20Me%20a%20Coffee-Support-FFDD00?logo=buymeacoffee&logoColor=black)](https://buymeacoffee.com/josuamarcelc)
