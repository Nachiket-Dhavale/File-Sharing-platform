#!/bin/bash
set -euo pipefail

PROJECT_DIR="/root/file-sharing-platform"
cd "$PROJECT_DIR"

echo "Loading environment variables..."
set -a
source .env
set +a

TIMESTAMP=$(date +"%Y-%m-%d_%H-%M-%S")
BACKUP_DIR="$PROJECT_DIR/backups/$TIMESTAMP"

mkdir -p "$BACKUP_DIR"

echo "======================================"
echo " Starting backup: $TIMESTAMP"
echo " Backup directory: $BACKUP_DIR"
echo "======================================"

echo "Checking required containers..."
docker ps --format '{{.Names}}' | grep -q '^postgres$' || { echo "postgres container not running"; exit 1; }
docker ps --format '{{.Names}}' | grep -q '^nextcloud$' || { echo "nextcloud container not running"; exit 1; }

echo "Enabling Nextcloud maintenance mode..."
docker exec -u www-data nextcloud php occ maintenance:mode --on

cleanup() {
  echo "Disabling Nextcloud maintenance mode..."
  docker exec -u www-data nextcloud php occ maintenance:mode --off || true
}
trap cleanup EXIT

echo "Backing up PostgreSQL database..."
docker exec -e PGPASSWORD="$POSTGRES_PASSWORD" postgres \
  pg_dump -U "$POSTGRES_USER" -d "$POSTGRES_DB" \
  > "$BACKUP_DIR/postgres.sql"

echo "Backing up Nextcloud data volume..."
docker run --rm \
  -v file-sharing-platform_nextcloud_data:/data:ro \
  -v "$BACKUP_DIR":/backup \
  alpine \
  tar czf /backup/nextcloud_data.tar.gz -C /data .

echo "Backing up Nginx certificate directory..."
if [ -d "$PROJECT_DIR/nginx/certs" ]; then
  tar czf "$BACKUP_DIR/nginx_certs.tar.gz" -C "$PROJECT_DIR/nginx" certs
else
  echo "No nginx/certs directory found, skipping certificate backup."
fi

echo "Saving configuration reference files..."
cp compose.yaml "$BACKUP_DIR/compose.yaml"
cp .env.example "$BACKUP_DIR/.env.example"
cp nginx/default.conf "$BACKUP_DIR/nginx-default.conf"

echo "Creating backup summary..."
cat > "$BACKUP_DIR/backup-info.txt" <<EOF
Backup timestamp: $TIMESTAMP
Project directory: $PROJECT_DIR

Included:
- PostgreSQL database dump: postgres.sql
- Nextcloud data volume: nextcloud_data.tar.gz
- Nginx certificates: nginx_certs.tar.gz, if available
- Compose/config reference files

Important:
- .env is not included because it contains secrets.
- Store .env separately in a secure password manager or secrets vault.
EOF

echo "======================================"
echo " Backup completed successfully"
echo " Location: $BACKUP_DIR"
echo "======================================"
