# 🛡️ DDoS Prevention Toolkit (Nginx + Ubuntu)

Stop random-query floods like `/?abc=RANDOM` at Nginx and auto-block abusive IPs.

## ✅ Install (3 steps)

1. Copy files to system paths:

```bash
cp config/nginx/conf.d/cloudflare-real-ip.conf /etc/nginx/conf.d/
cp config/nginx/conf.d/ddos-global.conf /etc/nginx/conf.d/
cp config/nginx/snippets/ddos-global.conf /etc/nginx/snippets/
cp scripts/ddos-nginx-autoblock.sh /usr/local/sbin/
cp config/cron/ddos-nginx-autoblock /etc/cron.d/
touch /etc/nginx/ddos-blocklist-generated.conf
chmod +x /usr/local/sbin/ddos-nginx-autoblock.sh
```

2. Enable in all vhosts (inside each `server { }` block):

```nginx
include snippets/ddos-global.conf;
```

3. Test and reload:

```bash
nginx -t
systemctl reload nginx
/usr/local/sbin/ddos-nginx-autoblock.sh
```

## ⚙️ How It Works

- Nginx drops random-query floods with `444`.
- A script scans the access log and builds `/etc/nginx/ddos-blocklist-generated.conf`.
- Cron runs the script every 20 minutes.

Cron file:

```cron
*/20 * * * * root SCAN_LINES=5000 /usr/local/sbin/ddos-nginx-autoblock.sh >/var/log/ddos-nginx-autoblock.log 2>&1
```

## 🔍 Quick Check

```bash
nginx -t
tail -n 2000 /var/log/nginx/access.log | awk '{print $9}' | sort | uniq -c | sort -nr
tail -n 50 /var/log/ddos-nginx-autoblock.log
```

## 💛 Support This Project

If this helped you, you can support here:

- PayPal: `https://www.paypal.me/josuamarcelc/1`
- Buy Me a Coffee: `https://buymeacoffee.com/josuamarcelc`
