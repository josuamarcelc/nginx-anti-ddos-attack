# Nginx Anti-DDoS Toolkit

The unsentimental version: **what actually works, what doesn't, and why.**

→ Setup is in **[ddos-toolkit-v3/README.md](ddos-toolkit-v3/README.md)**.

---

## The truth

DDoS isn't one thing. It's a layered problem and most "anti-DDoS" config posts are layer-3 advice for a layer-7 problem (or vice versa). Here's the part nobody puts in the README:

**You cannot stop a serious DDoS at the origin.** A determined attacker with a botnet of 100k devices can flood any single VPS, dedicated server, or rack — your nginx config is irrelevant if the pipe is full. Origin-side defense buys you time and stops scrapers, not floods.

**The protection layers that actually matter, in order:**

1. **Network-edge (Cloudflare, Fastly, AWS Shield, Akamai)** — absorbs L3/L4 floods at hundreds of Gbps. *Without this, you cannot survive a real DDoS.* Period.
2. **Origin firewall lockdown** — blocks direct-IP traffic so your origin is reachable only via the edge. Without this, point #1 is bypassable the moment your IP leaks.
3. **Origin rate limiting + behavioral filters** — handles the trickle that gets through the edge: bot scrapers, low-volume L7 abuse, dumb scanners. This is the visible part of "anti-DDoS" but it's the smallest contributor.
4. **Kernel sysctl** — keeps the OS from dying when the connection table fills. Background hardening, not a defense by itself.
5. **fail2ban / IP-level bans** — stops repeat offenders from coming back. Useful for slow attacks, useless for floods.

**This toolkit handles 2-5.** Layer 1 is your responsibility — sign up for Cloudflare's free tier, switch to orange-cloud DNS, done. There's a Cloudflare-side checklist in [ddos-toolkit-v3/docs/cloudflare-hardening.md](ddos-toolkit-v3/docs/cloudflare-hardening.md).

## What this toolkit will and won't do for you

| | What it stops | What it doesn't |
|---|---|---|
| Scrapers, recon scanners, dumb bots | ✓ | |
| Single-IP rate flooders | ✓ | |
| Slow-loris, slow-POST, hung-connection abuse | ✓ | |
| SQLi/XSS/LFI in query strings (basic patterns) | ✓ | (not a WAF — sophisticated payloads still get through) |
| Botnet DDoS at hundreds of Gbps | | ✗ — you need Cloudflare/Fastly/etc |
| Application-logic abuse (e.g. expensive search loops) | | ✗ — that's an app problem, fix the query |
| Direct-IP attacks on a leaked origin IP | | ✗ — until you run [`firewall/ufw-cloudflare-only.sh`](ddos-toolkit-v3/firewall/ufw-cloudflare-only.sh) |

## 🚀 Three commands

Everything is one of three scripts at the project root. Each has working `--help`.

```bash
git clone https://github.com/josuamarcelc/nginx-anti-ddos-attack.git
cd nginx-anti-ddos-attack/ddos-toolkit-v3
```

### 1. `install.sh` — **apply the toolkit**

```bash
sudo ./install.sh --dry-run         # preview every change (recommended first run)
sudo ./install.sh                   # apply with safe defaults
sudo ./install.sh --apply-ufw       # also lock the origin to Cloudflare IPs (destructive)
sudo ./install.sh --help            # full reference
```

Detects existing nginx config and only writes non-conflicting files. Backs up every overwritten file. Writes a manifest at `/etc/nginx/ddos-toolkit-manifest-<ts>.txt` so [`rollback.sh`](ddos-toolkit-v3/rollback.sh) can reverse the install exactly. If `nginx -t` fails, the install auto-reverts.

### 2. `rollback.sh` — **reverse any install**

```bash
sudo ./rollback.sh                  # reverse the most recent install
sudo ./rollback.sh --list           # show every install on this server
sudo ./rollback.sh <manifest>       # reverse a specific install
sudo ./rollback.sh --dry-run        # preview the reversal
sudo ./rollback.sh --help           # full reference
```

Reads the manifest, removes added files, restores backed-up files in place, reloads nginx + fail2ban + sysctl. Each manifest gets renamed to `*.rolled-back-<ts>.txt` after successful reversal so you can't accidentally roll back the same install twice.

### 3. `configure.sh` — **alert webhook + thresholds**

```bash
sudo ./configure.sh                                 # interactive prompts
sudo ./configure.sh --discord-webhook  https://discord.com/api/webhooks/<id>/<token>
sudo ./configure.sh --slack-webhook    https://hooks.slack.com/services/<T>/<B>/<X>
sudo ./configure.sh --test                          # POST a real test alert
sudo ./configure.sh --show                          # current config (URL masked)
sudo ./configure.sh --set REQUESTS_THRESHOLD=50     # any single key
sudo ./configure.sh --help                          # full reference
```

Writes `/etc/default/ddos-toolkit`. The cron'd behavior engine re-sources it every minute — no service restart needed. Where to get the URL:

- **Discord:** channel → ⚙ Edit Channel → Integrations → Webhooks → New Webhook → Copy URL
- **Slack:** [api.slack.com](https://api.slack.com) → Your Apps → pick app → Incoming Webhooks → Add Webhook → Copy URL

## Repo layout

```
nginx-anti-ddos-attack/
├── README.md                          ← this file
├── ddos-toolkit-v2/                   ← simple version (rate limit + IP autoblock only)
└── ddos-toolkit-v3/                   ← full stack
    ├── install.sh                     ← idempotent installer with manifest
    ├── rollback.sh                    ← reverse any install
    ├── README.md                      ← detailed setup
    ├── config/
    │   ├── nginx/                     ← rate limits, real-IP, request-shape filters, cache
    │   ├── sysctl/99-ddos-hardening.conf
    │   ├── cron/                      ← schedules for the auto-blocker
    │   └── logrotate/
    ├── firewall/
    │   └── ufw-cloudflare-only.sh     ← origin lockdown — opt-in, destructive
    ├── fail2ban/
    │   ├── jail.local                 ← jails for nginx-ddos / -noscript / -badbots
    │   └── filter.d/*.conf
    ├── scripts/
    │   ├── ddos-behavior-engine.sh    ← adaptive per-IP blocker (cron'd every minute)
    │   ├── ddos-nginx-autoblock.sh    ← legacy threshold-based blocker
    │   ├── update-cloudflare-ips.sh   ← refresh CF IP allowlist
    │   └── cache-warmup.sh            ← pre-compress static files
    └── docs/
        └── cloudflare-hardening.md    ← Cloudflare-side checklist (the layer that actually matters)
```

## License

Pick MIT or whatever fits your project; the toolkit is meant to be copied and adapted.
