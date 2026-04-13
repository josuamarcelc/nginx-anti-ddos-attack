# 🛡️ DDoS Prevention Toolkit v3.0 (Nginx + Ubuntu)

Multi-layer DDoS prevention: kernel hardening, rate limiting, connection limits, pattern-based flood detection, bad UA/referer blocking, HTTP smuggling detection, IP auto-blocking with subnet aggregation, TTL-based blocklist expiry, and attack alerting.

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

## ✅ Quick Install

```bash
git clone https://github.com/YOUR_REPO/ddos-toolkit.git
cd ddos-toolkit
sudo ./install.sh
```

### Manual Install

```bash
# Nginx configs
cp config/nginx/conf.d/cloudflare-real-ip.conf /etc/nginx/conf.d/
cp config/nginx/conf.d/ddos-global.conf        /etc/nginx/conf.d/
cp config/nginx/snippets/ddos-global.conf       /etc/nginx/snippets/
cp config/nginx/snippets/ddos-auth.conf         /etc/nginx/snippets/
cp config/nginx/snippets/ddos-post.conf         /etc/nginx/snippets/
cp config/nginx/snippets/ddos-download.conf     /etc/nginx/snippets/

# Blocklist + whitelist
cp config/nginx/ddos-blocklist-generated.conf   /etc/nginx/
cp config/nginx/ddos-whitelist.conf             /etc/nginx/

# Scripts
cp scripts/ddos-nginx-autoblock.sh              /usr/local/sbin/
cp scripts/update-cloudflare-ips.sh             /usr/local/sbin/
chmod +x /usr/local/sbin/ddos-nginx-autoblock.sh
chmod +x /usr/local/sbin/update-cloudflare-ips.sh

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
ddos-toolkit/
├── install.sh                              # Automated installer
├── config/
│   ├── nginx/
│   │   ├── conf.d/
│   │   │   ├── cloudflare-real-ip.conf     # CF IP ranges (auto-updated)
│   │   │   └── ddos-global.conf            # http{} context: zones, maps, geo
│   │   ├── snippets/
│   │   │   ├── ddos-global.conf            # server{} block: all protections
│   │   │   ├── ddos-auth.conf              # login/admin rate limiting
│   │   │   ├── ddos-post.conf              # POST endpoint rate limiting
│   │   │   └── ddos-download.conf          # download bandwidth limiting
│   │   ├── ddos-blocklist-generated.conf   # auto-managed blocklist
│   │   └── ddos-whitelist.conf             # never-block list (CIDR supported)
│   ├── cron/
│   │   └── ddos-nginx-autoblock            # cron jobs
│   ├── logrotate/
│   │   └── ddos-toolkit                    # log rotation config
│   └── sysctl/
│       └── 99-ddos-hardening.conf          # kernel network hardening
└── scripts/
    ├── ddos-nginx-autoblock.sh             # auto-detection + blocking engine
    └── update-cloudflare-ips.sh            # CF IP range updater
```

## 💛 Support This Project

If this helped you, you can support here:

[![PayPal](https://img.shields.io/badge/PayPal-Donate-00457C?logo=paypal&logoColor=white)](https://www.paypal.me/josuamarcelc/1)
[![Buy Me a Coffee](https://img.shields.io/badge/Buy%20Me%20a%20Coffee-Support-FFDD00?logo=buymeacoffee&logoColor=black)](https://buymeacoffee.com/josuamarcelc)
