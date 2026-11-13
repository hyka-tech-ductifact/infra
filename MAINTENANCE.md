# Server maintenance

Run commands from `~/ductifact/infra` on the target server. Runtime files remain
on the server; CI replaces them during deployment. Make persistent changes in
[configuration inputs](README.md#configuration).

## Logs and health

```bash
docker compose --env-file .env.production logs -f --tail=100
./scripts/checks/health.sh production
sudo journalctl -u caddy -u cloudflared -f
```

Use `.env.staging` / `staging` for that environment.

## Database backups

```bash
./scripts/ops/db.sh backup production
./scripts/ops/db.sh list production
./scripts/ops/db.sh restore staging /path/to/backup.sql.gz
```

Backups default to `~/backups/ductifact/<env>/` with seven-day retention.
Set `BACKUP_DIR` to change the base directory. Files are gzip-compressed PostgreSQL
custom-format archives. Restore asks for confirmation and replaces the database;
if it fails after stopping the backend, inspect the database before restarting it.
Omit the backup path to restore the latest backup for the selected environment.

For daily production backups, add to the deployment user's crontab:

```cron
0 3 * * * cd ~/ductifact/infra && ./scripts/ops/db.sh backup production
```

## Database diagnostics

Open a database session using the container's own credentials:

```bash
docker compose --env-file .env.staging exec postgres \
  sh -c 'psql -U "$POSTGRES_USER" -d "$POSTGRES_DB"'
```

Useful queries inside that session:

```sql
SELECT * FROM schema_migrations;
SELECT relname, n_live_tup FROM pg_stat_user_tables ORDER BY n_live_tup DESC;
SELECT pg_size_pretty(pg_database_size(current_database()));
```

## Reset staging database and object storage

This deletes staging database records and uploaded objects. Back up anything you
need first; this procedure does not reset Redis or monitoring data.

```bash
./scripts/ops/deploy.sh staging stop
docker volume rm ductifact-staging_postgres_data ductifact-staging_rustfs_data
./scripts/ops/deploy.sh staging
```

## Rollback

Open a PR setting `BACKEND_IMAGE` and `FRONTEND_IMAGE` in
`environments/production.manifest.env` to the last known good versions. Assign a
new, unused `RELEASE_VERSION` so release publication does not collide with an
existing tag. Merge to trigger the [production deployment](README.md#deployment-flow).
Application rollback does not undo database migrations.

For an urgent temporary rollback, edit those image references in the server's
`.env.production`, then run:

```bash
./scripts/ops/deploy.sh production
```

Record the same images in the manifest afterwards; the next CI deployment replaces
the server's runtime file.

## Server updates

```bash
sudo apt update
sudo apt upgrade
cloudflared --version
sudo systemctl status caddy cloudflared
```

Reboot if an installed update requires it.

If `cloudflared` was installed from the standalone Debian package, update it with:

```bash
curl -fL https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-amd64.deb \
  -o /tmp/cloudflared.deb
sudo dpkg -i /tmp/cloudflared.deb
sudo systemctl restart cloudflared
```

For tunnel diagnostics, use `cloudflared tunnel info ductifact` and `sudo ss -tlnp`
to inspect tunnel connections and local listening ports. Dashboard Access policies
and the host firewall must be checked separately; Compose alone does not define them.

## Credential changes

CI applies current GitHub secrets on the next deployment. Changing `DB_PASSWORD`
does not update the password inside an existing PostgreSQL volume; rotate that
database password as well, keeping the runtime configuration consistent.

## Migrating existing object storage to RustFS

For environments still using the previous object store:

1. Configure `S3_ACCESS_KEY` and `S3_SECRET_KEY` in both GitHub Environments.
2. Back up the old store. Start RustFS separately with a fresh volume, and set up
   `rclone` remotes named `source` and `destination`, using the existing bucket name.
3. Pause uploads/deletes, copy the objects, and verify them:

   ```bash
   rclone copy source:BUCKET destination:BUCKET
   rclone check source:BUCKET destination:BUCKET --download
   ```

4. Attach the populated volume to the Compose `s3` service, deploy staging first,
   and verify existing images through the API before resuming writes.

The Compose volume is `ductifact-<env>_rustfs_data`. Keep the old store until the
migration is verified; its data format cannot be mounted directly into RustFS.
Deployment does not migrate objects. RustFS metrics export is not configured yet.
