#!/usr/bin/env bash
#
# Fremd-Plugins und Composer-Stand von Live in die Zielumgebung holen. Läuft AUF dem Zielsystem
# (Stage per SSH mit Agent-Forwarding, ddev lokal im Shop-Repo), gestartet per `ops shop:plugins:sync <ziel>`.
#
# Live ist die Composer-Wahrheit (Entscheidung 19.10.2026): composer.json und composer.lock kommen von Live,
# danach composer install und die Cache-Kette. WebLabels, ShopPlugin und EssmannFaq bleiben auf dem Git-Stand.
#
# Umgebung (setzt ops): ROOT, PHP, MARKER_DIR, SOURCE (user@host oder Alias von Live), SOURCE_ROOT,
#   COMPOSER (composer | ddev composer), RSYNC_FLAGS (extra), DRY_RUN (0/1)
set -euo pipefail

ROOT="${ROOT:?}"
PHP="${PHP:?}"
SOURCE="${SOURCE:?}"
SOURCE_ROOT="${SOURCE_ROOT:?}"
COMPOSER="${COMPOSER:-composer}"
MARKER_DIR="${MARKER_DIR:?}"
RSYNC_FLAGS="${RSYNC_FLAGS:-}"
DRY_RUN="${DRY_RUN:-0}"
console() { $PHP bin/console "$@"; }

if [ -t 1 ]; then C_STEP=$'\033[1;34m'; C_OK=$'\033[1;32m'; C_END=$'\033[0m'; else C_STEP=''; C_OK=''; C_END=''; fi
step() { printf '\n%s==> %s%s\n' "$C_STEP" "$1" "$C_END"; }

cd "$ROOT"
DRY=''
[ "$DRY_RUN" = 1 ] && DRY='--dry-run'

step "Fremd-Plugin-Dateien von Live spiegeln (eigene Plugins ausgenommen)"
# shellcheck disable=SC2086
rsync -a --delete $DRY $RSYNC_FLAGS --itemize-changes \
  --exclude=WebLabels --exclude=ShopPlugin --exclude=EssmannFaq \
  --exclude=.DS_Store --exclude=.gitignore --exclude=.gitkeep \
  --exclude=webla_zusatzoptionen.zip --exclude=node_modules \
  -e ssh "$SOURCE:$SOURCE_ROOT/custom/plugins/" "$ROOT/custom/plugins/" | grep -v '^\.d' | sed 's/^/  /' || true

step "Composer-Stand von Live holen"
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
ssh "$SOURCE" "cat $SOURCE_ROOT/composer.json" > "$TMP/composer.json"
ssh "$SOURCE" "cat $SOURCE_ROOT/composer.lock" > "$TMP/composer.lock"
[ -s "$TMP/composer.lock" ] || { echo "composer.lock von Live ist leer, Abbruch." >&2; exit 1; }

# Paket-Unterschiede zwischen dem Lock hier und dem von Live (lokales PHP reicht, es liest nur JSON)
php -r '
  $old = json_decode(file_get_contents($argv[1]), true)["packages"] ?? [];
  $new = json_decode(file_get_contents($argv[2]), true)["packages"] ?? [];
  $o = []; foreach ($old as $p) { $o[$p["name"]] = $p["version"]; }
  $n = []; foreach ($new as $p) { $n[$p["name"]] = $p["version"]; }
  $rows = [];
  foreach ($n as $name => $v) { if (!isset($o[$name])) { $rows[] = "  + $name $v"; } elseif ($o[$name] !== $v) { $rows[] = "  ~ $name {$o[$name]} -> $v"; } }
  foreach ($o as $name => $v) { if (!isset($n[$name])) { $rows[] = "  - $name $v"; } }
  echo $rows ? implode("\n", $rows) . "\n" : "  keine Paket-Unterschiede\n";
  exit(0);
' -- "$ROOT/composer.lock" "$TMP/composer.lock"

if [ "$DRY_RUN" = 1 ]; then
  echo; echo "Trockenlauf: nichts geändert."; exit 0
fi

if cmp -s "$TMP/composer.lock" "$ROOT/composer.lock" && cmp -s "$TMP/composer.json" "$ROOT/composer.json"; then
  echo "  composer.json und composer.lock sind schon auf Live-Stand."
else
  cp "$TMP/composer.json" "$ROOT/composer.json"
  cp "$TMP/composer.lock" "$ROOT/composer.lock"
  step "Composer install"
  $COMPOSER install --no-interaction --optimize-autoloader --no-scripts
fi

step "Plugins registrieren, Cache, Assets, Theme"
console plugin:refresh --quiet
console cache:clear
console assets:install
console theme:compile --active-only
console cache:clear
console cache:pool:clear cache.object cache.http cache.tags || true

mkdir -p "$MARKER_DIR"
printf 'at=%s\nby=%s\nsource=live\nlock=%s\n' "$(date '+%Y-%m-%d %H:%M')" "$(whoami)" "$(php -r 'echo substr(md5_file($argv[1]),0,8);' -- "$ROOT/composer.lock")" > "$MARKER_DIR/last-plugins"
printf '\n%sFremd-Plugins und Composer-Stand sind auf Live-Stand.%s\n' "$C_OK" "$C_END"
