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
docker compose --env-file .env.prod logs -f

# All staging services
docker compose --env-file .env.staging logs -f
```

---

## 2. Database Backups

### Automated backups (recommended)

Use `scripts/db.sh` to manage backups:

```bash
# Create a backup (saves to /var/backups/ductifact/<env>/)
./scripts/db.sh backup prod

# List available backups
./scripts/db.sh list prod

# Restore the latest backup
./scripts/db.sh restore prod

# Restore a specific backup
./scripts/db.sh restore prod /var/backups/ductifact/prod/20260412_030000.sql.gz
```

### Cron setup (daily at 3:00 AM)

```bash
crontab -e
0 3 * * * cd /opt/ductifact && ./scripts/db.sh backup prod >> /var/log/ductifact-backup.log 2>&1
```

Retention: 7 days (configurable in `db.sh`).

### Database diagnostics

```bash
# Load environment variables first
source .env.staging   # or .env.prod

# Check current migration version
docker exec ductifact_${ENV}_postgres \
  psql -U $DB_USER -d $DB_NAME -c "SELECT * FROM schema_migrations;"

# Row count per table
docker exec ductifact_${ENV}_postgres \
  psql -U $DB_USER -d $DB_NAME -c "SELECT relname, n_live_tup FROM pg_stat_user_tables ORDER BY n_live_tup DESC;"

# Database size
docker exec ductifact_${ENV}_postgres \
  psql -U $DB_USER -d $DB_NAME -c "SELECT pg_size_pretty(pg_database_size('$DB_NAME'));"

# List available backups
ls -lh /var/backups/ductifact/${ENV}/
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
docker compose --env-file .env.prod stop app

# Edit .env.prod temporarily: IMAGE_TAG=v0.3.0
docker compose --env-file .env.prod up -d app
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
docker compose --env-file .env.staging down

# Remove the data volumes (staging only!)
docker volume rm ductifact_staging_postgres_data ductifact_staging_minio_data

# Bring it back up
docker compose --env-file .env.staging up -d
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
