# Server Maintenance Guide

Operational procedures for the Ductifact production and staging environments running on Debian 12 with Cloudflare Tunnel.

---

## 1. Viewing Logs

```bash
# Production API (last 100 lines, live)
docker logs -f --tail=100 ductifact_prod_app

# Staging API
docker logs -f --tail=100 ductifact_staging_app

# Caddy (reverse proxy)
sudo journalctl -u caddy -f

# Cloudflare Tunnel
sudo journalctl -u cloudflared -f

# All production services
docker compose -f docker-compose.prod.yml logs -f

# All staging services
docker compose -f docker-compose.staging.yml logs -f
```

---

## 2. Database Backups

### Manual backup

```bash
# Production
docker exec ductifact_prod_postgres \
  pg_dump -U ductifact_user ductifact_db > ~/backups/prod_$(date +%Y%m%d).sql

# Staging
docker exec ductifact_staging_postgres \
  pg_dump -U ductifact_staging_user ductifact_staging_db > ~/backups/staging_$(date +%Y%m%d).sql

# Restore
cat ~/backups/prod_20260320.sql | docker exec -i ductifact_prod_postgres \
  psql -U ductifact_user ductifact_db
```

### Automated backups (cron)

```bash
# Edit deploy user's crontab
crontab -e

# Daily production backup at 3am, keep last 7 days
0 3 * * * docker exec ductifact_prod_postgres pg_dump -U ductifact_user ductifact_db | gzip > ~/backups/prod_$(date +\%Y\%m\%d).sql.gz && find ~/backups -name "prod_*.sql.gz" -mtime +7 -delete

# Daily staging backup at 4am (optional, less critical), keep last 3 days
0 4 * * * docker exec ductifact_staging_postgres pg_dump -U ductifact_staging_user ductifact_staging_db | gzip > ~/backups/staging_$(date +\%Y\%m\%d).sql.gz && find ~/backups -name "staging_*.sql.gz" -mtime +3 -delete
```

---

## 3. Rollback

If a production deploy breaks something, you have two options:

### Option 1: Quick rollback with Docker (seconds)

Use this for emergencies when the API is down and you need to restore immediately.

```bash
cd ~/ductifact/infra

# List available image versions
docker images ghcr.io/your-user/ductifact

# Stop the current version
docker compose --env-file .env.prod -f docker-compose.prod.yml stop app

# Temporarily change the image in docker-compose.prod.yml
# image: ghcr.io/your-user/ductifact:v0.3.0
docker compose --env-file .env.prod -f docker-compose.prod.yml up -d app
```

### Option 2: Hotfix via the `release` branch (minutes, the correct way)

This is the proper flow described in `CONTRIBUTING.md` §7. It leaves a proper trail in git (tag, PR, CI-validated).

```bash
# 1. Create hotfix from release
git checkout -b hotfix/fix-urgent-bug origin/release

# 2. Fix, test, PR → release
# 3. Tag a new patch version on release
git checkout release && git pull
git tag -a v0.4.1 -m "Hotfix v0.4.1"
git push origin v0.4.1
# → CD automatically deploys to production

# 4. Merge back to main
git checkout main && git pull
git merge release
git push origin main
```

---

## 4. Server Security Updates

```bash
# Every 1–2 weeks
ssh deploy@ssh.jcapsule.work
sudo apt update && sudo apt upgrade -y

# If the kernel was updated, reboot
sudo reboot
```

---

## 5. Updating cloudflared

```bash
# Check current version
cloudflared --version

# Update
curl -L https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-amd64.deb \
  -o /tmp/cloudflared.deb
sudo dpkg -i /tmp/cloudflared.deb
sudo systemctl restart cloudflared
```

---

## 6. Resetting Staging

When staging accumulates test data and you want a clean slate:

```bash
cd ~/ductifact/infra

# Stop staging completely
docker compose --env-file .env.staging -f docker-compose.staging.yml down

# Remove the data volume (staging only!)
docker volume rm ductifact_staging_postgres_data

# Bring it back up (GORM AutoMigrate recreates tables on app startup)
docker compose --env-file .env.staging -f docker-compose.staging.yml up -d
```

---

## 7. Cloudflare Security

### 7.1 Verify only Cloudflare can access your server

Even though no ports are open (thanks to the tunnel), it's good practice to verify:

```bash
# List listening ports on the server
sudo ss -tlnp

# You should see services listening, but UFW blocks them from the internet:
#   *:22    (SSH — only accessible from LAN and Cloudflare Tunnel)
#   *:80    (Caddy — only accessible from localhost/cloudflared)
#   *:3000  (Grafana — only accessible from localhost/Caddy)
```

No port is open to the public in the firewall. `cloudflared` and Caddy communicate via localhost. The LAN accesses services through the `ufw allow from 192.168.x.0/24` rules.

### 7.2 Recommended Cloudflare Dashboard settings

| Setting | Value | Explanation |
|---------|-------|-------------|
| SSL/TLS mode | **Full (strict)** | Cloudflare verifies the certificate between its edge and your server. With tunnel, Full is sufficient. |
| Always Use HTTPS | **On** | Automatically redirects HTTP to HTTPS. |
| Minimum TLS Version | **1.2** | Blocks clients with outdated (insecure) TLS. |
| Browser Integrity Check | **On** | Blocks requests with suspicious user-agents. |
| Bot Fight Mode | **On** | Additional protection against malicious bots. |

### 7.3 Restricting access to staging (optional)

If you want staging to be accessible only to you:

1. Go to **Cloudflare Dashboard → Zero Trust → Access → Applications**
2. Create an application for `staging-api.ductifact.jcapsule.work`
3. Set up a policy that only allows your email
4. Cloudflare will require authentication before granting access

This prevents bots or curious users from accessing staging.

### 7.4 Verify Cloudflare Tunnel status

```bash
# On the server
sudo systemctl status cloudflared

# View tunnel logs
sudo journalctl -u cloudflared -f --no-pager | tail -20

# Check active connections
cloudflared tunnel info ductifact
```
