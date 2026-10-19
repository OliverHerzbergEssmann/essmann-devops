#!/usr/bin/env bash
#
# Server-Teil des Stage-Deploys. Läuft AUF dem Stage-Server (herzberg), gestartet per `ops shop:deploy stage`,
# das vorher main -> stage gemergt und gepusht hat und diese Datei bei jedem Aufruf hochlädt.
# Ersetzt /usr/local/bin/deploy-stage (root-owned; kannte das EssmannFaq-Submodule nicht).
#
# Umgebung (setzt ops aus config/environments.yaml): CHECKOUT, ROOT, BRANCH, URL, MARKER_DIR
set -euo pipefail

CHECKOUT="${CHECKOUT:-/home/herzberg/monorepo}"
ROOT="${ROOT:-/var/www/shopware}"
BRANCH="${BRANCH:-stage}"
URL="${URL:-http://essmann-shop.essmann.intern}"
MARKER_DIR="${MARKER_DIR:-$HOME/.essmann-ops/shop}"
PLUGINS="$ROOT/custom/plugins"
PHP=$(command -v php)
console() { sudo -u www-data "$PHP" "$ROOT/bin/console" "$@"; }

if [ -t 1 ]; then C_STEP=$'\033[1;34m'; C_OK=$'\033[1;32m'; C_END=$'\033[0m'; else C_STEP=''; C_OK=''; C_END=''; fi
step() { printf '\n%s==> %s%s\n' "$C_STEP" "$1" "$C_END"; }

step "Git: $BRANCH in $CHECKOUT holen (inkl. Submodule)"
cd "$CHECKOUT"
git fetch origin
git checkout "$BRANCH"
git pull --ff-only origin "$BRANCH"
git submodule update --init --recursive
SHA=$(git rev-parse --short HEAD)
OLD_VERSION=$(php -r 'echo json_decode(@file_get_contents($argv[1]), true)["version"] ?? "";' -- "$PLUGINS/ShopPlugin/composer.json")
NEW_VERSION=$(php -r 'echo json_decode(@file_get_contents($argv[1]), true)["version"] ?? "";' -- "$CHECKOUT/custom/plugins/ShopPlugin/composer.json")
echo "Stand $SHA, ShopPlugin $OLD_VERSION -> $NEW_VERSION"

step "Plugins nach $PLUGINS kopieren"
for plugin in WebLabels ShopPlugin EssmannFaq; do
  echo "  $plugin"
  rm -rf "${PLUGINS:?}/$plugin/"
  rsync -a --info=stats0,flist0 --delete --delete-excluded --exclude=vendor --exclude=.git --exclude=node_modules \
    --exclude=.claude --exclude=AGENTS.md --no-group --no-owner \
    "$CHECKOUT/custom/plugins/$plugin/" "$PLUGINS/$plugin/"
done

step "Composer install"
cd "$ROOT"
composer install --no-interaction --optimize-autoloader --no-scripts

step "Plugins und Migrationen"
console plugin:refresh --quiet
if [ -n "$NEW_VERSION" ] && [ "$OLD_VERSION" != "$NEW_VERSION" ]; then
  echo "  neue ShopPlugin-Version: plugin:update Essmann"
  console plugin:update Essmann
fi
console database:migrate --all Essmann
console database:migrate --all WebLabels

step "Cache, Assets, Theme (Reihenfolge ist Absicht, siehe DEPLOYMENT.md)"
console cache:clear
console assets:install
console theme:refresh || true
console theme:compile --active-only
console cache:clear
console cache:pool:clear cache.object cache.http cache.tags

step "PHP-Opcache über alle FPM-Worker leeren"
for i in $(seq 1 30); do curl -sk -o /dev/null "$URL/clear_cache.php"; done

mkdir -p "$MARKER_DIR"
printf 'at=%s\nby=%s\nsha=%s\nbranch=%s\nversion=%s\n' "$(date '+%Y-%m-%d %H:%M')" "$(whoami)" "$SHA" "$BRANCH" "$NEW_VERSION" > "$MARKER_DIR/last-deploy"

printf '\n%sStage deployt: %s (ShopPlugin %s).%s\n' "$C_OK" "$SHA" "$NEW_VERSION" "$C_END"
