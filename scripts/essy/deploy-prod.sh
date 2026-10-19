#!/usr/bin/env bash
#
# Deployt ESSY in die laufende Installation auf dem Server (Code als herzberg, Console als www-data).
# Läuft AUF dem Server, gestartet per `ops essy:deploy prod`, das diese Datei bei jedem Aufruf hochlädt.
#
# Das ist der heutige Aufbau (/var/www/kern-poc, FPM als www-data). Der Aufbau mit Release-Ordnern,
# eigenem Benutzer und Rollback aus kern-poc/bin/deploy.sh ist davon unabhängig und wartet auf die
# Einrichtung durch die IT (kern-poc/docs/DEPLOYMENT.md).
#
# Umgebung (setzt ops): CHECKOUT, ROOT, BRANCH, URL, MARKER_DIR, FORCE (0/1)
set -euo pipefail

CHECKOUT="${CHECKOUT:-$HOME/kern-poc}"
ROOT="${ROOT:-/var/www/kern-poc}"
BRANCH="${BRANCH:-main}"
URL="${URL:-http://essy.essmann.intern}"
MARKER_DIR="${MARKER_DIR:-$HOME/.essmann-ops/essy}"
FORCE="${FORCE:-0}"
# Was auf den Server gehört (dieselbe Liste wie PATHS in kern-poc/bin/deploy.sh); public ohne assets/ (kompiliert, gehört www-data)
PATHS=(assets bin/console config migrations public src templates .env composer.json composer.lock symfony.lock importmap.php)
PHP=$(command -v php)
console() { sudo -u www-data "$PHP" "$ROOT/bin/console" "$@"; }

if [ -t 1 ]; then C_STEP=$'\033[1;34m'; C_WARN=$'\033[1;33m'; C_OK=$'\033[1;32m'; C_END=$'\033[0m'; else C_STEP=''; C_WARN=''; C_OK=''; C_END=''; fi
step() { printf '\n%s==> %s%s\n' "$C_STEP" "$1" "$C_END"; }
warn() { printf '%sWARNUNG: %s%s\n' "$C_WARN" "$1" "$C_END" >&2; }
fail() { printf '\n\033[1;31mFEHLER: %s\033[0m\n' "$1" >&2; exit 1; }

step "Git: $BRANCH in $CHECKOUT holen"
[ -d "$CHECKOUT/.git" ] || fail "$CHECKOUT ist kein Git-Checkout."
[ -w "$ROOT" ] || fail "$ROOT ist für $(whoami) nicht beschreibbar."
cd "$CHECKOUT"
git fetch origin
git checkout "$BRANCH"
git pull --ff-only origin "$BRANCH"
SHA=$(git rev-parse --short HEAD)
LAST=$(sed -n 's/^sha=//p' "$MARKER_DIR/last-deploy" 2>/dev/null || true)
if [ "$SHA" = "$LAST" ] && [ "$FORCE" != 1 ]; then
  echo "Stand $SHA ist laut Marker schon deployt. --force deployt ihn trotzdem."
  exit 0
fi
echo "Stand $SHA (zuletzt deployt: ${LAST:-unbekannt})"

step "Dateien nach $ROOT kopieren"
for path in "${PATHS[@]}"; do
  [ -e "$CHECKOUT/$path" ] || fail "Im Checkout fehlt $path (Liste PATHS in diesem Skript und in kern-poc/bin/deploy.sh)."
  # -rl --checksum statt -a: keine Besitzer, Gruppen, Rechte und Zeiten setzen, einzelne Ordner im Ziel gehören www-data
  # (chgrp und utime scheitern sonst); ohne Zeiten entscheidet die Prüfsumme, was kopiert wird
  if [ -d "$CHECKOUT/$path" ]; then
    rsync -rl --checksum --info=stats0,flist0 --delete --exclude=/assets/ "$CHECKOUT/$path/" "$ROOT/$path/"
  else
    rsync -rl --checksum --info=stats0,flist0 "$CHECKOUT/$path" "$ROOT/$path"
  fi
done

step "Composer install"
cd "$ROOT"
composer install --no-interaction --no-dev --optimize-autoloader --no-scripts

step "Konfiguration prüfen, bevor die Datenbank berührt wird"
console app:environment:check --production

step "Datenbank sichern"
console app:db:backup --label=before-deploy

step "Migrationen"
console doctrine:migrations:migrate --no-interaction

step "Assets und Cache"
console asset-map:compile
console cache:clear
console app:environment:check --production

mkdir -p "$MARKER_DIR"
printf 'at=%s\nby=%s\nsha=%s\nbranch=%s\n' "$(date '+%Y-%m-%d %H:%M')" "$(whoami)" "$SHA" "$BRANCH" > "$MARKER_DIR/last-deploy"

step "Web-Test"
response=$(curl -s --max-time 30 -w '\n%{http_code}' "$URL/login" || true)
code="${response##*$'\n'}"
if [ "$code" = 200 ] && printf '%s' "$response" | grep -q 'ESSY</title>'; then
  echo "  /login: 200 mit ESSY-Titel"
else
  warn "/login antwortet mit $code oder ohne ESSY-Titel. Prüfe das Fehlerprotokoll des Pools."
  exit 2
fi
printf '\n%sESSY deployt: %s%s\n' "$C_OK" "$SHA" "$C_END"
