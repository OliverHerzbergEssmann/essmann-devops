#!/usr/bin/env bash
#
# Composer-Stand aus dem Shop-Repo (composer.json/composer.lock, auf ddev aktualisiert und geprüft) auf Stage oder
# Live einspielen. Läuft AUF dem Zielsystem, gestartet per `ops shop:composer:push <stage|live>`, das die beiden
# Dateien vorher nach NEW_JSON und NEW_LOCK hochgeladen hat.
#
# Gegenrichtung zu plugins-sync.sh, gedacht für Core-Updates in der Reihenfolge ddev -> Stage -> Live (Auftrag des
# Users, 18.11.2026). Fremd-Plugin-Ordner fasst das Skript nicht an. Danach ist der Stand überall gleich, Live bleibt
# die Composer-Wahrheit für alles, was dort direkt aktualisiert wird (Plugins).
#
# Reihenfolge nach dem Install wie in deploy-live.sh (Begründung: essmann-shop/DEPLOYMENT.md, Live-Deploy Schritt 7):
# Container neu bauen, Core-Migrationen, Assets, Theme, Cache, Redis-Pools, Opcache, Pools.
#
# Umgebung (setzt ops): ROOT, PHP, URL, MARKER_DIR, NEW_JSON, NEW_LOCK, DRY_RUN (0/1), SMOKE_LISTING_PATH,
#   OPCACHE  clear_cache = vorhandenes public/clear_cache.php aufrufen (Stage)
#            temp_file   = public/_oc.php anlegen, aufrufen, löschen (Live)
set -euo pipefail

ROOT="${ROOT:?}"
PHP="${PHP:?}"
URL="${URL:?}"
MARKER_DIR="${MARKER_DIR:?}"
NEW_JSON="${NEW_JSON:?}"
NEW_LOCK="${NEW_LOCK:?}"
DRY_RUN="${DRY_RUN:-0}"
OPCACHE="${OPCACHE:-clear_cache}"
SMOKE_LISTING_PATH="${SMOKE_LISTING_PATH:-/industriewaagen/}"
console() { $PHP "$ROOT/bin/console" "$@" 2> >(grep -v 'JIT is incompatible' >&2); }

if [ -t 1 ]; then C_STEP=$'\033[1;34m'; C_WARN=$'\033[1;33m'; C_OK=$'\033[1;32m'; C_END=$'\033[0m'; else C_STEP=''; C_WARN=''; C_OK=''; C_END=''; fi
step() { printf '\n%s==> %s%s\n' "$C_STEP" "$1" "$C_END"; }
warn() { printf '%sWARNUNG: %s%s\n' "$C_WARN" "$1" "$C_END" >&2; }
fail() { printf '\n\033[1;31mFEHLER: %s\033[0m\n' "$1" >&2; exit 1; }
trap 'rm -f "$NEW_JSON" "$NEW_LOCK"' EXIT

clear_pools() { console cache:pool:clear cache.object cache.http cache.tags; }
# Ein Aufruf trifft nur den einen FPM-Worker, der ihn bedient: deshalb 30x (DEPLOYMENT.md, Live-Deploy Schritt 8).
reset_opcache() {
  if [ "$OPCACHE" = temp_file ]; then
    php -r 'file_put_contents($argv[1] . "/public/_oc.php", "<?php opcache_reset(); echo \"OK\";");' -- "$ROOT"
    for _ in $(seq 1 30); do curl -sk -o /dev/null "$URL/_oc.php"; done
    rm -f "$ROOT/public/_oc.php"
  else
    for _ in $(seq 1 30); do curl -sk -o /dev/null "$URL/clear_cache.php"; done
  fi
}
# Wie in deploy-live.sh: Core-Migrationen vor Cache-Kette und Opcache-Reset, Post-Update-Ereignisse nur nach echten Migrationen.
migrate_core() {
  local out
  out=$(console database:migrate core --all 2>&1) || { printf '%s\n' "$out" >&2; fail "Core-Migrationen fehlgeschlagen. Cache und Opcache sind unverändert."; }
  echo "  core: $(grep -Eo 'Migrated +[0-9]+ out of [0-9]+' <<<"$out" | tr -s ' ' | head -1 || true)"
  if grep -Eq 'Migrated +[1-9][0-9]* out of' <<<"$out"; then
    echo "  Core-Migrationen gelaufen: Post-Update-Ereignisse nachholen"
    console system:update:finish --skip-migrations --skip-asset-build
  fi
}

cd "$ROOT"
[ -s "$NEW_LOCK" ] && [ -s "$NEW_JSON" ] || fail "composer.json oder composer.lock aus dem Repo fehlt oder ist leer."

step "Paket-Unterschiede: Stand hier -> Stand aus dem Repo"
php -r '
  $old = json_decode(file_get_contents($argv[1]), true);
  $new = json_decode(file_get_contents($argv[2]), true);
  $rows = [];
  foreach (["packages", "packages-dev"] as $key) {
    $o = []; foreach ($old[$key] ?? [] as $p) { $o[$p["name"]] = $p["version"]; }
    $n = []; foreach ($new[$key] ?? [] as $p) { $n[$p["name"]] = $p["version"]; }
    foreach ($n as $name => $v) { if (!isset($o[$name])) { $rows[] = "  + $name $v"; } elseif ($o[$name] !== $v) { $rows[] = "  ~ $name {$o[$name]} -> $v"; } }
    foreach ($o as $name => $v) { if (!isset($n[$name])) { $rows[] = "  - $name $v"; } }
  }
  echo $rows ? implode("\n", $rows) . "\n" : "  keine Paket-Unterschiede\n";
' -- "$ROOT/composer.lock" "$NEW_LOCK"
cmp -s "$NEW_JSON" "$ROOT/composer.json" || echo "  composer.json unterscheidet sich ebenfalls"

# Dev-Pakete nur, wenn sie hier schon installiert sind: der Install soll die Betriebsart des Ziels nicht ändern.
NO_DEV=''
if [ "$(php -r 'echo (json_decode((string) @file_get_contents($argv[1]), true)["dev"] ?? true) ? "1" : "0";' -- "$ROOT/vendor/composer/installed.json")" = 0 ]; then
  NO_DEV='--no-dev'
fi
echo "  composer install läuft hier ${NO_DEV:-mit Dev-Paketen (wie bisher)}"

if [ "$DRY_RUN" = 1 ]; then
  echo; echo "Trockenlauf: nichts geändert."; exit 0
fi

step "Alten Composer-Stand sichern"
BACKUP_DIR="$MARKER_DIR/composer-backup-$(date +%Y%m%d-%H%M%S)"
mkdir -p "$BACKUP_DIR"
cp "$ROOT/composer.json" "$ROOT/composer.lock" "$BACKUP_DIR/"
echo "  $BACKUP_DIR"

step "Composer install mit dem Stand aus dem Repo"
cp "$NEW_JSON" "$ROOT/composer.json"
cp "$NEW_LOCK" "$ROOT/composer.lock"
# shellcheck disable=SC2086
if ! composer install --no-interaction --optimize-autoloader --no-scripts $NO_DEV; then
  warn "composer install fehlgeschlagen: alter Stand wird wiederhergestellt"
  cp "$BACKUP_DIR/composer.json" "$BACKUP_DIR/composer.lock" "$ROOT/"
  # shellcheck disable=SC2086
  composer install --no-interaction --optimize-autoloader --no-scripts $NO_DEV || warn "Auch der Install des alten Stands ist fehlgeschlagen: vendor/ von Hand prüfen."
  fail "Composer-Stand nicht eingespielt. Cache und Opcache sind unverändert."
fi

step "Plugins registrieren, Core-Migrationen"
console plugin:refresh --quiet
console cache:clear
migrate_core

step "Assets, Theme, Cache, Opcache (Reihenfolge ist Absicht, siehe DEPLOYMENT.md)"
console assets:install
console theme:compile --active-only
console cache:clear
clear_pools
reset_opcache
clear_pools

VERSION=$(console --version 2>/dev/null | grep -Eo '[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+' | head -1 || true)
mkdir -p "$MARKER_DIR"
printf 'at=%s\nby=%s\nsource=repo\nlock=%s\nshopware=%s\nbackup=%s\n' "$(date '+%Y-%m-%d %H:%M')" "$(whoami)" "$(php -r 'echo substr(md5_file($argv[1]),0,8);' -- "$ROOT/composer.lock")" "$VERSION" "$BACKUP_DIR" > "$MARKER_DIR/last-composer"

step "Smoke-Test"
problems=0
# Der Server ruft seine eigene URL ab (Live über Cloudflare, sporadisch 522/000), deshalb mit Wiederholungen.
fetch() { curl -sk --max-time 30 --retry 3 --retry-delay 2 --retry-all-errors "$@" || true; }
code=$(curl -sk -o /dev/null -w '%{http_code}' --max-time 30 --retry 3 --retry-delay 2 --retry-all-errors "$URL/" || true)
[ "$code" = 200 ] && echo "  Startseite: 200" || { warn "Startseite antwortet mit $code"; problems=1; }
listing=$(fetch "$URL$SMOKE_LISTING_PATH")
if grep -q 'essmann-spec-table' <<<"$listing"; then echo "  Listing: essmann-spec-table vorhanden"; else warn "Listing $SMOKE_LISTING_PATH ohne essmann-spec-table"; problems=1; fi
login=$(fetch "$URL/account/login")
if grep -q 'noindex,nofollow' <<<"$login"; then echo "  /account/login: noindex,nofollow"; else warn "/account/login ohne noindex,nofollow"; problems=1; fi

if [ "$problems" = 1 ]; then
  warn "Smoke-Test mit Befunden. Rückweg: composer.json und composer.lock aus $BACKUP_DIR zurückkopieren, composer install, cache:clear, Pools, Opcache."
  exit 2
fi
printf '\n%sComposer-Stand eingespielt: Shopware %s. Sicherung des alten Stands: %s%s\n' "$C_OK" "$VERSION" "$BACKUP_DIR" "$C_END"
