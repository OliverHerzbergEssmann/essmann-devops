#!/usr/bin/env bash
#
# Server-Teil des Live-Deploys. Läuft AUF dem Live-Server (Shell-User web225), gestartet per
# `ops shop:deploy live`, das vorher release gepusht, das Live-DB-Backup gezogen und diese Datei hochgeladen hat.
# Setzt den manuellen Ablauf aus DEPLOYMENT.md ("Live-Deploy") Schritt für Schritt um.
#
# Umgebung (setzt ops): CHECKOUT, ROOT, BRANCH, URL, MARKER_DIR, GIT_SSH_COMMAND,
#   WITH_CATEGORY_CONTENT (0/1), SMOKE_LISTING_PATH, SMOKE_PRODUCT_PATH
set -euo pipefail

CHECKOUT="${CHECKOUT:-$HOME/essmann-shop-release}"
ROOT="${ROOT:-/var/www/clients/client80/web225/web}"
BRANCH="${BRANCH:-release}"
URL="${URL:-https://www.essmann-shop.com}"
MARKER_DIR="${MARKER_DIR:-$HOME/.essmann-ops/shop}"
WITH_CATEGORY_CONTENT="${WITH_CATEGORY_CONTENT:-0}"
SMOKE_LISTING_PATH="${SMOKE_LISTING_PATH:-/industriewaagen/}"
SMOKE_PRODUCT_PATH="${SMOKE_PRODUCT_PATH:-}"
export GIT_SSH_COMMAND="${GIT_SSH_COMMAND:-ssh -i $HOME/.ssh/id_ed25519_github_live -o IdentitiesOnly=yes}"
PLUGINS="$ROOT/custom/plugins"
console() { php "$ROOT/bin/console" "$@" 2> >(grep -v 'JIT is incompatible' >&2); }

if [ -t 1 ]; then C_STEP=$'\033[1;34m'; C_WARN=$'\033[1;33m'; C_OK=$'\033[1;32m'; C_END=$'\033[0m'; else C_STEP=''; C_WARN=''; C_OK=''; C_END=''; fi
step() { printf '\n%s==> %s%s\n' "$C_STEP" "$1" "$C_END"; }
warn() { printf '%sWARNUNG: %s%s\n' "$C_WARN" "$1" "$C_END" >&2; }
fail() { printf '\n\033[1;31mFEHLER: %s\033[0m\n' "$1" >&2; exit 1; }

clear_pools() { console cache:pool:clear cache.object cache.http cache.tags; }
reset_opcache() {
  # Ein Aufruf trifft nur den einen FPM-Worker, der ihn bedient: deshalb 30x (DEPLOYMENT.md, Schritt 8).
  php -r 'file_put_contents($argv[1] . "/public/_oc.php", "<?php opcache_reset(); echo \"OK\";");' -- "$ROOT"
  for i in $(seq 1 30); do curl -sk -o /dev/null "$URL/_oc.php"; done
  rm -f "$ROOT/public/_oc.php"
}

step "Git: $BRANCH in $CHECKOUT holen (inkl. Submodule)"
[ -d "$CHECKOUT/.git" ] || fail "$CHECKOUT ist kein Git-Checkout."
cd "$CHECKOUT"
git fetch origin
git checkout "$BRANCH"
git pull --ff-only origin "$BRANCH"
git submodule update --init --recursive
SHA=$(git rev-parse --short HEAD)
OLD_VERSION=$(php -r 'echo json_decode(@file_get_contents($argv[1]), true)["version"] ?? "";' -- "$PLUGINS/ShopPlugin/composer.json" 2>/dev/null)
NEW_VERSION=$(php -r 'echo json_decode(@file_get_contents($argv[1]), true)["version"] ?? "";' -- "$CHECKOUT/custom/plugins/ShopPlugin/composer.json" 2>/dev/null)
echo "Stand $SHA, ShopPlugin $OLD_VERSION -> $NEW_VERSION"

step "Plugin-Ordner sichern"
BACKUP="$HOME/plugins-backup-$(date +%F-%H%M).tar.gz"
tar czf "$BACKUP" -C "$ROOT" custom/plugins/WebLabels custom/plugins/ShopPlugin custom/plugins/EssmannFaq
echo "  $BACKUP"

step "Unterschiede zum laufenden Stand"
for plugin in WebLabels ShopPlugin EssmannFaq; do
  changed=$(diff -rq -x vendor -x .git -x node_modules -x .claude -x AGENTS.md "$CHECKOUT/custom/plugins/$plugin/" "$PLUGINS/$plugin/" 2>/dev/null | wc -l | tr -d ' ')
  echo "  $plugin: $changed Datei(en) anders"
done

step "Plugins nach $PLUGINS kopieren"
cd "$ROOT"
rsync -a --info=stats0,flist0 --delete --exclude=.claude --exclude=AGENTS.md "$CHECKOUT/custom/plugins/WebLabels/" "$PLUGINS/WebLabels/"
rsync -a --info=stats0,flist0 --delete --exclude=.claude --exclude=AGENTS.md "$CHECKOUT/custom/plugins/ShopPlugin/" "$PLUGINS/ShopPlugin/"
rsync -a --info=stats0,flist0 --delete --delete-excluded --exclude=vendor --exclude=.git --no-group --no-owner "$CHECKOUT/custom/plugins/EssmannFaq/" "$PLUGINS/EssmannFaq/"

step "Plugins und Migrationen"
console plugin:refresh --quiet
if [ -n "$NEW_VERSION" ] && [ "$OLD_VERSION" != "$NEW_VERSION" ]; then
  echo "  neue ShopPlugin-Version: plugin:update Essmann"
  console plugin:update Essmann
else
  echo "  gleiche ShopPlugin-Version: database:migrate --all Essmann (findet nur Migrationen, die der Container schon kennt)"
  console database:migrate --all Essmann
fi

step "Cache, Assets, Theme (Reihenfolge ist Absicht, DEPLOYMENT.md Schritt 7 bis 8a)"
console cache:clear
console assets:install
console theme:compile --active-only
console cache:clear
clear_pools
reset_opcache
clear_pools

if [ "$WITH_CATEGORY_CONTENT" = 1 ]; then
  step "Kategorie-Inhalte und FAQ neu importieren (DEPLOYMENT.md Schritt 9)"
  console essmann:setup:category-content-block
  console essmann:import:category-content --write
  console essmann:import:category-faq --write
  console essmann:cleanup:legacy-seo-slot --write
  clear_pools
  console cache:clear
  reset_opcache
  clear_pools
fi

mkdir -p "$MARKER_DIR"
printf 'at=%s\nby=%s\nsha=%s\nbranch=%s\nversion=%s\nbackup=%s\n' "$(date '+%Y-%m-%d %H:%M')" "$(whoami)" "$SHA" "$BRANCH" "$NEW_VERSION" "$BACKUP" > "$MARKER_DIR/last-deploy"

step "Smoke-Test"
problems=0
code=$(curl -sk -o /dev/null -w '%{http_code}' --max-time 30 "$URL/")
[ "$code" = 200 ] && echo "  Startseite: 200" || { warn "Startseite antwortet mit $code"; problems=1; }
listing=$(curl -sk --max-time 30 "$URL$SMOKE_LISTING_PATH")
if printf '%s' "$listing" | grep -q 'essmann-spec-table'; then echo "  Listing: essmann-spec-table vorhanden"; else warn "Listing $SMOKE_LISTING_PATH ohne essmann-spec-table"; problems=1; fi
if [ -n "$SMOKE_PRODUCT_PATH" ]; then
  blocks=$(curl -sk --max-time 30 "$URL$SMOKE_PRODUCT_PATH" | grep -o 'application/ld+json' | wc -l | tr -d ' ')
  [ "$blocks" = 2 ] && echo "  Produktseite: 2 ld+json-Blöcke" || { warn "Produktseite hat $blocks ld+json-Blöcke statt 2 (Opcache? Alt-Plugin?)"; problems=1; }
fi
if curl -sk --max-time 30 "$URL/account/login" | grep -q 'noindex,nofollow'; then echo "  /account/login: noindex,nofollow"; else warn "/account/login ohne noindex,nofollow"; problems=1; fi

if [ "$problems" = 1 ]; then
  warn "Smoke-Test mit Befunden. Rückweg: tar xzf $BACKUP -C $ROOT, dann cache:clear, Pools, Opcache."
  exit 2
fi
printf '\n%sLive deployt: %s (ShopPlugin %s). Plugin-Backup: %s%s\n' "$C_OK" "$SHA" "$NEW_VERSION" "$BACKUP" "$C_END"
