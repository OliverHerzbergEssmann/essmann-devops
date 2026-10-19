#!/usr/bin/env bash
# Liest den Zustand einer Shop-Installation und gibt key=value-Zeilen aus. Ändert nichts.
# Umgebung: ROOT, PHP (PHP-Aufruf als der Benutzer von var/), CHECKOUT (optional), MARKER_DIR
set -u
cd "$ROOT" 2>/dev/null || { echo "error=Wurzel fehlt: $ROOT"; exit 0; }
echo "php=$($PHP -r 'echo PHP_VERSION;' 2>/dev/null | tail -1)"
# Dateien liest das PHP der Shell hier (ohne sudo/ddev): die Schnipsel enthalten $-Variablen, die eine zweite Shell verschlucken würde
echo "shopware=$(php -r '$l=json_decode(file_get_contents("composer.lock"),true); foreach ($l["packages"] as $p) { if ($p["name"]==="shopware/core") { echo ltrim($p["version"],"v"); } }' 2>/dev/null | tail -1)"
echo "plugin=$(php -r 'echo json_decode(file_get_contents("custom/plugins/ShopPlugin/composer.json"),true)["version"] ?? "";' 2>/dev/null | tail -1)"
echo "lock=$(php -r 'echo substr(md5_file("composer.lock"),0,8);' 2>/dev/null | tail -1)"
echo "foreign_plugins=$(ls -1 custom/plugins 2>/dev/null | grep -v -E '^(WebLabels|ShopPlugin|EssmannFaq|\.|.*\.zip$)' | wc -l | tr -d ' ')"
if [ -n "${CHECKOUT:-}" ] && [ -d "$CHECKOUT/.git" ]; then
  echo "checkout_sha=$(git -C "$CHECKOUT" rev-parse --short HEAD 2>/dev/null)"
  echo "checkout_branch=$(git -C "$CHECKOUT" branch --show-current 2>/dev/null)"
  echo "checkout_date=$(git -C "$CHECKOUT" log -1 --format=%cs 2>/dev/null)"
  echo "checkout_dirty=$(git -C "$CHECKOUT" status --porcelain 2>/dev/null | wc -l | tr -d ' ')"
fi
for marker in last-deploy last-sync last-plugins; do
  file="${MARKER_DIR:-$HOME/.essmann-ops/shop}/$marker"
  [ -f "$file" ] && sed "s/^/${marker#last-}_/" "$file"
done
exit 0
