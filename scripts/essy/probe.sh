#!/usr/bin/env bash
# Liest den Zustand einer ESSY-Installation und gibt key=value-Zeilen aus. Ändert nichts.
# Umgebung: ROOT, PHP (PHP-Aufruf als der Benutzer von var/), CHECKOUT (optional), MARKER_DIR
set -u
cd "$ROOT" 2>/dev/null || { echo "error=Wurzel fehlt: $ROOT"; exit 0; }
echo "php=$($PHP -r 'echo PHP_VERSION;' 2>/dev/null | tail -1)"
# Dateien liest das PHP der Shell hier; nur var/ (gehört dem Benutzer von PHP-FPM) über $PHP, ohne $-Variablen im Schnipsel
echo "symfony=$(php -r '$l=json_decode(file_get_contents("composer.lock"),true); foreach ($l["packages"] as $p) { if ($p["name"]==="symfony/framework-bundle") { echo ltrim($p["version"],"v"); } }' 2>/dev/null | tail -1)"
echo "lock=$(php -r 'echo substr(md5_file("composer.lock"),0,8);' 2>/dev/null | tail -1)"
echo "last_backup=$($PHP -r 'echo glob("var/backups/*") ? date("Y-m-d H:i", max(array_map("filemtime", glob("var/backups/*")))) : "";' 2>/dev/null | tail -1)"
echo "db_size=$($PHP -r 'echo is_file("var/data/app.sqlite") ? round(filesize("var/data/app.sqlite")/1024) . " KB" : "";' 2>/dev/null | tail -1)"
if [ -n "${CHECKOUT:-}" ] && [ -d "$CHECKOUT/.git" ]; then
  echo "checkout_sha=$(git -C "$CHECKOUT" rev-parse --short HEAD 2>/dev/null)"
  echo "checkout_branch=$(git -C "$CHECKOUT" branch --show-current 2>/dev/null)"
  echo "checkout_date=$(git -C "$CHECKOUT" log -1 --format=%cs 2>/dev/null)"
  echo "checkout_dirty=$(git -C "$CHECKOUT" status --porcelain 2>/dev/null | wc -l | tr -d ' ')"
fi
for marker in last-deploy; do
  file="${MARKER_DIR:-$HOME/.essmann-ops/essy}/$marker"
  [ -f "$file" ] && sed "s/^/${marker#last-}_/" "$file"
done
exit 0
