# Cloudflare hardening checklist

Origin protection (UFW + nginx + fail2ban + sysctl) is layer 1. Cloudflare is layer 0 — what an attacker hits first. **If Cloudflare is loose, everything you did at the origin barely matters.** This doc walks the orange-cloud configuration that pairs cleanly with the rest of this toolkit.

> Why it matters: a typical L7 DDoS sees 100k–1M req/s. Origin-only protection scales to about 10k req/s before nginx itself becomes the bottleneck. Cloudflare's free tier already absorbs the long tail — but only if it's actually in front.

---

## 1. DNS — orange cloud everywhere that serves users

In **Cloudflare Dashboard → DNS → Records**:

- Every `A`, `AAAA`, `CNAME` record that maps to a public service must be **proxied** (orange cloud, not gray).
- Gray-cloud (DNS-only) records leak your origin IP into public DNS — anyone running `dig` finds it instantly.
- Subdomains for non-HTTP services (mail.example.com, ssh-bastion.example.com) can stay gray, but **never share an IP with your proxied origin**. Put mail/SSH on a separate IP or behind a separate provider, otherwise the IP is still discoverable.

A common leak path: a `mail.example.com` record points at the same IP as `example.com` (orange). An attacker queries `mail.example.com` → gets the origin IP → hits port 80/443 directly, bypassing the orange cloud. Defense: separate IP for mail, OR use the [`firewall/ufw-cloudflare-only.sh`](../firewall/ufw-cloudflare-only.sh) script in this repo to make port 80/443 unreachable except from CF ranges.

---

## 2. SSL/TLS — Full (strict)

**Dashboard → SSL/TLS → Overview**

- Set encryption to **Full (strict)**. Anything else (Flexible, Full) is either plaintext-to-origin or accepts forged certs.
- Origin certificate: generate a free Cloudflare Origin CA cert (15-year validity) and install it on nginx. Bonus: it's only valid for connections from Cloudflare, so direct-IP HTTPS probes can't even establish TLS.
- **Always Use HTTPS**: ON
- **Automatic HTTPS Rewrites**: ON
- **Min TLS Version**: 1.2 (1.3 is fine if your client base supports it; 1.0/1.1 should be gone)
- **HSTS**: enable with a 12-month max-age, includeSubdomains, preload — but only AFTER you're sure everything works on HTTPS, this is hard to undo.

---

## 3. Bot management

**Dashboard → Security → Bots**

- **Bot Fight Mode**: ON. Free tier; signs JS challenges to confirmed-bot ASNs.
- **Verified Bots**: allow legitimate crawlers (Googlebot, Bingbot, Apple, etc.) — bypass the WAF rules below for these.
- For paid plans (Pro+): **Super Bot Fight Mode** with the "Definitely automated" tier set to `Block`, "Likely automated" to `Managed Challenge`.

---

## 4. WAF custom rules

**Dashboard → Security → WAF → Custom rules**

These four rules cover ~80% of L7 abuse. All free-tier compatible.

### Rule 1 — Block empty / well-known scanner UAs

```
(http.user_agent eq "")
or
(lower(http.user_agent) contains "nikto")
or
(lower(http.user_agent) contains "sqlmap")
or
(lower(http.user_agent) contains "masscan")
or
(lower(http.user_agent) contains "nmap")
or
(lower(http.user_agent) contains "wpscan")
or
(lower(http.user_agent) contains "nuclei")
or
(lower(http.user_agent) contains "acunetix")
```

Action: **Block**. (Mirrors the nginx `ddos-advanced.conf` filter, but at the edge so they never reach origin.)

### Rule 2 — Challenge requests on auth/login paths

```
(http.request.uri.path matches "/(login|signin|admin|wp-login|api/auth|api/login)")
and (cf.threat_score gt 5)
```

Action: **Managed Challenge**. (Real users solve a checkbox; bots fail.)

### Rule 3 — Block paths that aren't yours

```
http.request.uri.path matches "/(wp-admin|wp-includes|xmlrpc\.php|\.env|\.git|/cgi-bin)"
and not (http.host eq "www.your-wordpress-site.com")
```

Action: **Block**. Avoid pinning by URI alone — only block these paths on hosts that don't legitimately serve them.

### Rule 4 — Geo-block if you don't operate there

```
(ip.geoip.country in {"RU" "KP" "IR"})
```

Action: **Block** or **JS Challenge**. Use only when your audience is regional. Mistakes here lock out real users — log first, block second.

---

## 5. Rate limiting

**Dashboard → Security → WAF → Rate limiting rules**

Free tier: 1 rule, 10k requests/10s threshold. Paid tiers: more rules + lower thresholds.

| Path | Limit | Action |
|---|---|---|
| `/login`, `/signin`, `/api/auth` | 5 req / 1 min per IP | Block 1 hour |
| `/api/*` | 100 req / 10 sec per IP | Managed Challenge |
| Whole zone | 200 req / 10 sec per IP | Managed Challenge |

Mirror these in nginx via `ddos-strict` zone (already provided in `conf.d/ddos-global.conf`) so the protection survives if Cloudflare is bypassed.

---

## 6. Page Rules / Cache Rules

**Dashboard → Caching → Cache Rules**

Force caching on your static surface so Cloudflare absorbs the attack volume:

- `*example.com/*.{css,js,png,jpg,jpeg,gif,svg,woff,woff2,ttf,eot}` → **Edge cache TTL: 1 month**
- `*example.com/*.html` (static sites): **Edge cache TTL: 5 minutes** with `respect origin Cache-Control: ON`

The `cache-warmup.sh` in this repo helps you pre-compress static assets before that first cache fill.

---

## 7. Turnstile on forms

For login, signup, contact, and search forms:

- Replace reCAPTCHA / hCaptcha with [Cloudflare Turnstile](https://developers.cloudflare.com/turnstile/) (free, GDPR-clean, invisible for most users).
- Server-side: validate the `cf-turnstile-response` token with `siteverify`.
- Pairs with WAF Rule 2 above for layered protection.

---

## 8. Origin lockdown (the part Cloudflare can't do for you)

Once Cloudflare is in front, **you must block direct-IP traffic** to ports 80/443:

```bash
sudo ./firewall/ufw-cloudflare-only.sh
```

This script:
- Resets UFW
- Allows SSH (port 22 by default; `--ssh-port N` to change)
- Allows ports 80/443 ONLY from `https://www.cloudflare.com/ips-v4` and `ips-v6`
- Drops everything else

Without this, scrapers and L4 floods that already know your origin IP completely ignore Cloudflare. With this, even if your IP leaks, attackers hit a closed port.

---

## 9. Notification + analytics

**Dashboard → Notifications**

Set up alerts on:
- DDoS attack detected (any layer)
- Sudden traffic spike (≥10x the rolling 1-hour avg)
- Origin error rate spike (≥10% 5xx)
- Worker error spike (if you use Workers)

Where to send: webhook → Discord / Slack / PagerDuty. Same channel you used for the [server-wide PHP error forwarder](../../README.md) is fine; it's already proven.

---

## 10. Quick verification checklist

Run these after every config change:

```
curl -I https://example.com                           # → has cf-ray header
curl -I --resolve example.com:443:<ORIGIN_IP> ...     # → connection refused (UFW working)
curl -A 'sqlmap/1.0' https://example.com              # → 403/444 from CF
curl -X POST -d "email=' OR 1=1--" https://example.com/login   # → 403 from CF
ab -n 10000 -c 100 https://example.com/               # → most served from edge cache
```

If all five behave as expected, you're done.

---

## Failure modes

- **Cloudflare goes down**: rare but happens (~1× per quarter). Without origin lockdown, you can flip DNS to direct-IP and survive. With origin lockdown, you survive only if you also have a backup CDN/load-balancer in front. Trade-off: lockdown is strictly safer, but you need a recovery plan for the rare CF outage.
- **Scrape across CF**: low-volume scrapers blend in with normal traffic. Bot Fight Mode helps; Turnstile on suspicious paths helps more.
- **Slow attacks (slowloris, slow POST)**: blocked by `client_*_timeout` in `ddos-advanced.conf` *and* by Cloudflare's connection management. Both layers; you only need one to fire.
