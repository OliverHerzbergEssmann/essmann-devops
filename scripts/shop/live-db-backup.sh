#!/usr/bin/env bash
#
# Erstellt ein retiniertes Backup der Live-Datenbank, bevor ein Live-Deploy etwas
# an Live ändert. Anders als db-sync.sh (Prod -> Stage) und .ddev/commands/host/db-pull
# (Prod -> ddev) wird hier NICHTS gelöscht: der Dump bleibt sowohl auf Live
# (~/backups/ im Home-Verzeichnis, nicht /tmp) als auch lokal auf dem Mac (var/) liegen,
# bis er manuell aufgeräumt wird.
#
# Usage: ./live-db-backup.sh
# Voraussetzung: SSH-Alias "prod" (öffentlich erreichbar, kein VPN nötig, siehe
# .ddev/commands/host/db-pull für dieselbe Credential-Auslese-Technik).

set -euo pipefail

SSH_ALIAS="prod"
LOCAL_DIR="${LOCAL_DIR:-var}"

echo "→ Erstelle retiniertes DB-Backup auf Live (kann etwas dauern)..."

REMOTE_PATH=$(ssh "$SSH_ALIAS" 'bash -s' << 'REMOTE_SCRIPT'
set -euo pipefail
trap 'rm -f /tmp/.my_essmann_backup.cnf' EXIT

# PHP liest .env + .env.local, schreibt temp my.cnf mit korrekten Credentials
# (gleiche Technik wie .ddev/commands/host/db-pull)
DB_NAME=$(php -r "
    \$env = [];
    foreach (['.env', '.env.local'] as \$f) {
        \$path = '/var/www/clients/client80/web225/web/' . \$f;
        if (!file_exists(\$path)) continue;
        foreach (file(\$path) as \$line) {
            \$line = trim(\$line);
            if (\$line === '' || \$line[0] === '#' || strpos(\$line, '=') === false) continue;
            [\$k, \$v] = explode('=', \$line, 2);
            \$env[trim(\$k)] = trim(\$v, chr(34) . chr(39));
        }
    }
    if (empty(\$env['DATABASE_URL'])) { fwrite(STDERR, 'DATABASE_URL nicht gefunden.' . PHP_EOL); exit(1); }
    \$url = parse_url(\$env['DATABASE_URL']);
    \$cnf  = '[client]' . PHP_EOL;
    \$cnf .= 'user='     . \$url['user'] . PHP_EOL;
    \$cnf .= 'password=' . urldecode(\$url['pass']) . PHP_EOL;
    \$cnf .= 'host='     . \$url['host'] . PHP_EOL;
    \$cnf .= 'port='     . (\$url['port'] ?? 3306) . PHP_EOL;
    file_put_contents('/tmp/.my_essmann_backup.cnf', \$cnf);
    echo ltrim(\$url['path'], '/');
")

mkdir -p ~/backups
TIMESTAMP=$(date +%Y%m%d-%H%M%S)
BACKUP_FILE=~/backups/essmann-live-backup-${TIMESTAMP}.sql.gz

mysqldump \
    --defaults-file=/tmp/.my_essmann_backup.cnf \
    --single-transaction \
    --quick \
    --no-tablespaces \
    "$DB_NAME" | gzip > "$BACKUP_FILE"

# Absoluter Pfad fürs scp auf dem Mac
readlink -f "$BACKUP_FILE"
REMOTE_SCRIPT
)

echo "→ Backup auf Live: $REMOTE_PATH"

# Prüfen ob Dump plausibel groß ist — verhindert ein stilles, leeres/kaputtes Backup
ACTUAL_SIZE=$(ssh "$SSH_ALIAS" "stat -c%s '$REMOTE_PATH'")
MIN_SIZE=10000

if [ "$ACTUAL_SIZE" -lt "$MIN_SIZE" ]; then
    echo "Fehler: Backup ist verdächtig klein (${ACTUAL_SIZE} Bytes) – möglicherweise fehlgeschlagen."
    exit 1
fi

echo "→ Ziehe Kopie aufs Mac ($(( ACTUAL_SIZE / 1024 / 1024 )) MB)..."
mkdir -p "$LOCAL_DIR"
scp "$SSH_ALIAS:$REMOTE_PATH" "$LOCAL_DIR/"

echo ""
echo "Fertig. Backup liegt an zwei Orten:"
echo "  - Live: $REMOTE_PATH"
echo "  - Mac:  $LOCAL_DIR/$(basename "$REMOTE_PATH")"
echo ""
echo "Restore im Notfall (auf Live, per ssh $SSH_ALIAS):"
echo "  gunzip -c $REMOTE_PATH | mysql --defaults-file=<credentials-siehe-oben> <db_name>"
