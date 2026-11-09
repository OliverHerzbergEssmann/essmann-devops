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
# Offene Core-Migrationen (composer u ohne Migrationen, Live 09.11.2026): Migrationsklassen aus vendor V6_3..V6_<minor>
# (wie MigrationCollectionLoader::collectAllForVersion) gegen die Tabelle migration, nur lesend. Läuft mit $PHP
# (Rechte auf .env.local); der Code geht per stdin hinein, weil ddev exec $-Variablen und Klammern in -r verschluckt.
pending=$($PHP 2>/dev/null <<'PHP' | tail -1
<?php
error_reporting(0);
require 'vendor/autoload.php';
if (is_file('.env') || is_file('.env.dist') || is_file('.env.local.php')) {
    (new Symfony\Component\Dotenv\Dotenv())->usePutenv()->bootEnv(getcwd() . '/.env');
}
$minor = (int) explode('.', (string) Composer\InstalledVersions::getVersion('shopware/core'))[1];
$all = [];
for ($m = 3; $m <= $minor; ++$m) {
    foreach (glob("vendor/shopware/core/Migration/V6_$m/Migration*.php") ?: [] as $file) {
        $all["Shopware\\Core\\Migration\\V6_$m\\" . basename($file, '.php')] = true;
    }
}
$done = Shopware\Core\Kernel::getConnection()->fetchFirstColumn('SELECT class FROM migration WHERE `update` IS NOT NULL');
echo count(array_diff_key($all, array_flip($done)));
PHP
)
case "$pending" in ''|*[!0-9]*) pending='?' ;; esac
echo "core_migrations_pending=$pending"
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
