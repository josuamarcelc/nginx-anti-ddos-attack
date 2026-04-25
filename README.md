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

## Install (60 seconds)

```bash
git clone https://github.com/josuamarcelc/nginx-anti-ddos-attack.git
cd nginx-anti-ddos-attack/ddos-toolkit-v3

sudo ./install.sh --dry-run    # preview every change
sudo ./install.sh              # apply (safe-by-default; UFW lockdown stays manual)
```

The installer:
- Detects existing nginx config and skips files that conflict.
- Backs up every file it overwrites to `/etc/nginx/ddos-backup-<timestamp>/`.
- Writes a manifest at `/etc/nginx/ddos-toolkit-manifest-<timestamp>.txt`.
- Validates `nginx -t` after install. Auto-rolls-back the nginx pieces if the test fails.
- Skips fail2ban / UFW gracefully if the binaries aren't installed.

## Rollback

```bash
sudo ./rollback.sh                # reverse the most recent install
sudo ./rollback.sh --list         # list every install on this server
sudo ./rollback.sh <manifest>     # roll back a specific install
sudo ./rollback.sh --dry-run      # preview the reversal
```

Rollback uses the manifest to:
- Delete every file the install added.
- Restore every file the install overwrote, from the backup dir.
- Reload nginx and (if applicable) fail2ban.

The backup dir is **never deleted** — even after rollback, you can pull individual files out manually.

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
