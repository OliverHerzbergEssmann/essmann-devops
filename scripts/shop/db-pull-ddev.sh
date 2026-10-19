#!/usr/bin/env bash
#
# DB-Sync Live -> ddev. Läuft auf dem Mac im Shop-Repo, gestartet per `ops shop:db:sync ddev`
# (oder weiter per `ddev db-pull`, das darauf verweist).
#
# Standardmäßig ohne Kunden-/Bestell-/Anfragedaten; --with-customer-data übernimmt alles (Order-Debugging).
# Danach gilt immer: Captcha aus, URLs umgeschrieben, admin/shopware vorhanden, kein Tracking, Mailer auf Mailpit.
#
MARKER_DIR="${MARKER_DIR:-$HOME/.essmann-ops/shop-ddev}"
SHOP_ROOT="${DDEV_APPROOT:-$(pwd)}"
cd "$SHOP_ROOT"
set -euo pipefail

# Standardmäßig ohne Kunden-/Bestell-/Anfragedaten (analog `db-sync.sh` für Stage) —
# mit --with-customer-data alles übernehmen (z.B. für Order-Debugging):
#   ddev db-pull --with-customer-data
WITH_CUSTOMER_DATA=0
for arg in "$@"; do
    case "$arg" in
        --with-customer-data)
            WITH_CUSTOMER_DATA=1
            ;;
        *)
            echo "Unbekannter Parameter: $arg" >&2
            echo "Usage: db-pull [--with-customer-data]" >&2
            exit 1
            ;;
    esac
done

SSH_ALIAS="prod"
PROD_PLUGINS_PATH="/var/www/clients/client80/web225/web/custom/plugins"
TMP_FILE="/tmp/essmann-live-db.sql.gz"

# Muss vor dem DB-Import laufen: sonst kann der Container an Plugin-Klassen scheitern, die die
# frisch importierte Live-DB referenziert, es lokal aber noch nicht gibt. WebLabels/ShopPlugin/
# EssmannFaq sind versioniert und bleiben bewusst auf main-Stand, nicht auf Live-Stand.
echo "→ Fremd-Plugin-Dateien von Live spiegeln (nicht versioniert, sonst driften sie auseinander)..."
rsync -a --delete \
    --exclude=WebLabels --exclude=ShopPlugin --exclude=EssmannFaq \
    --exclude=.DS_Store --exclude=.gitignore --exclude=.gitkeep \
    --exclude=webla_zusatzoptionen.zip --exclude=node_modules \
    -e ssh \
    "$SSH_ALIAS:$PROD_PLUGINS_PATH/" \
    "$SHOP_ROOT/custom/plugins/"

echo "→ Erstelle Dump auf dem Server (kann etwas dauern)..."

ssh "$SSH_ALIAS" 'bash -s' > "$TMP_FILE" << 'REMOTE_SCRIPT'
set -euo pipefail

trap 'rm -f /tmp/.my_essmann.cnf' EXIT

# PHP liest .env + .env.local, schreibt temp my.cnf mit korrekten Credentials
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
    file_put_contents('/tmp/.my_essmann.cnf', \$cnf);
    echo ltrim(\$url['path'], '/');
")

echo "→ Datenbank: $DB_NAME" >&2

mysqldump \
    --defaults-file=/tmp/.my_essmann.cnf \
    --single-transaction \
    --quick \
    --no-tablespaces \
    "$DB_NAME" | sed "s/ALTER DATABASE \`$DB_NAME\`/ALTER DATABASE \`db\`/g" | gzip
REMOTE_SCRIPT

# Prüfen ob Dump plausibel groß ist — verhindert Import eines leeren/kaputten Dumps
ACTUAL_SIZE=$(stat -f%z "$TMP_FILE" 2>/dev/null || stat -c%s "$TMP_FILE")
MIN_SIZE=10000

if [ "$ACTUAL_SIZE" -lt "$MIN_SIZE" ]; then
    echo "Fehler: Dump ist zu klein (${ACTUAL_SIZE} Bytes) – möglicherweise fehlgeschlagen. Import abgebrochen."
    rm -f "$TMP_FILE"
    exit 1
fi

echo "→ Sichere lokale DooFinder-Config (eigener ddev-Account + Management-API-Zugangsdaten, sonst überschreibt Live sie mit dem Produktions-Account)..."
DOOFINDER_BACKUP="/tmp/essmann-doofinder-config-backup.sql"
ddev exec mysqldump db --no-create-info --skip-add-locks --compact --replace \
    --where="configuration_key LIKE 'DooFinder.config.%' OR configuration_key LIKE 'Essmann.config.doofinder%'" system_config > "$DOOFINDER_BACKUP" 2>/dev/null || true

echo "→ Importiere in ddev ($(( ACTUAL_SIZE / 1024 / 1024 )) MB)..."
ddev import-db --file="$TMP_FILE"

rm -f "$TMP_FILE"

echo "→ Verkaufskanäle auf ddev-URL anpassen..."
ddev exec mysql db -e "UPDATE sales_channel_domain SET url = REPLACE(url, 'https://www.essmann-shop.com', 'https://essmann-shop.ddev.site');"

echo "→ EssmannFAQ-Plugin war auf Live nie installiert – Plugin-Zeile ggf. nachtragen (sonst kann der Container nicht mehr booten: 'has a dependency on a non-existent service ... essmann_faq_group.repository', da ShopPlugin fest auf diesen Service verweist)..."
ddev exec mysql db <<'SQL'
INSERT INTO plugin (id, name, base_class, composer_name, active, managed_by_composer, path, autoload, version, installed_at, created_at)
SELECT UNHEX(REPLACE(UUID(), '-', '')), 'EssmannFAQ', 'Essmann\\FAQ\\EssmannFAQ', 'essmann/faq', 1, 0, 'custom/plugins/EssmannFaq/', '{"psr-4":{"Essmann\\\\FAQ\\\\":"src\\/"}}', '1.3.3', NOW(3), NOW(3)
FROM DUAL
WHERE NOT EXISTS (SELECT 1 FROM plugin WHERE name = 'EssmannFAQ');

INSERT INTO plugin_translation (plugin_id, language_id, label, description, created_at)
SELECT p.id, lang.id, 'Essmann FAQ', 'FAQ-Verwaltung für Kategorien, Produkte und allgemeine Themen', NOW(3)
FROM plugin p
JOIN (SELECT l.id FROM language l JOIN locale lo ON lo.id = l.locale_id WHERE lo.code = 'de-DE' LIMIT 1) AS lang ON 1=1
WHERE p.name = 'EssmannFAQ'
  AND NOT EXISTS (SELECT 1 FROM plugin_translation pt WHERE pt.plugin_id = p.id AND pt.language_id = lang.id);

INSERT INTO plugin_translation (plugin_id, language_id, label, description, created_at)
SELECT p.id, lang.id, 'Essmann FAQ', 'FAQ management for categories, products and general topics', NOW(3)
FROM plugin p
JOIN (SELECT l.id FROM language l JOIN locale lo ON lo.id = l.locale_id WHERE lo.code = 'en-GB' LIMIT 1) AS lang ON 1=1
WHERE p.name = 'EssmannFAQ'
  AND NOT EXISTS (SELECT 1 FROM plugin_translation pt WHERE pt.plugin_id = p.id AND pt.language_id = lang.id);
SQL

echo "→ Cache leeren..."
ddev exec bin/console cache:clear --quiet

echo "→ Storefront neu kompilieren..."
ddev exec bin/console theme:compile --active-only

echo "→ Trigger auf lokalen Definer umstellen (Live-DEFINER existiert lokal nicht, sonst scheitern Writes/Migrationen auf 'country' mit MySQL-Fehler 1449)..."
ddev exec mysql db <<'SQL'
DROP TRIGGER IF EXISTS country_tax_free_insert;
DROP TRIGGER IF EXISTS country_tax_free_update;
SQL
ddev exec mysql db <<'SQL'
DELIMITER $$

CREATE DEFINER=CURRENT_USER TRIGGER country_tax_free_insert
BEFORE INSERT ON country
FOR EACH ROW
BEGIN
                IF @TRIGGER_DISABLED IS NULL OR @TRIGGER_DISABLED = 0 THEN
                    IF NEW.tax_free = 1 OR NEW.customer_tax IS NULL THEN
                        SET NEW.customer_tax = JSON_OBJECT("enabled", NEW.tax_free, "currencyId", 'b7d2554b0ce847cd82f3ac9bd1c0dfca', "amount", 0);
                    ELSEIF NEW.customer_tax IS NOT NULL THEN
                        SET NEW.tax_free = JSON_EXTRACT(NEW.customer_tax, "$.enabled");
                    END IF;
                    IF NEW.company_tax_free = 1 OR NEW.company_tax IS NULL THEN
                        SET NEW.company_tax = JSON_OBJECT("enabled", NEW.company_tax_free, "currencyId", 'b7d2554b0ce847cd82f3ac9bd1c0dfca', "amount", 0);
                    ELSEIF NEW.company_tax IS NOT NULL THEN
                        SET NEW.company_tax_free = JSON_EXTRACT(NEW.company_tax, "$.enabled");
                    END IF;
                END IF;
            END$$

CREATE DEFINER=CURRENT_USER TRIGGER country_tax_free_update
BEFORE UPDATE ON country
FOR EACH ROW
BEGIN
                IF @TRIGGER_DISABLED IS NULL OR @TRIGGER_DISABLED = 0 THEN
                    IF NEW.tax_free <> OLD.tax_free THEN
                        SET NEW.customer_tax = JSON_OBJECT("enabled", NEW.tax_free, "currencyId", JSON_EXTRACT(OLD.customer_tax, "$.currencyId"), "amount", JSON_EXTRACT(OLD.customer_tax, "$.amount"));
                    ELSEIF NEW.tax_free = OLD.tax_free AND JSON_EXTRACT(NEW.customer_tax, "$.enabled") <> JSON_EXTRACT(OLD.customer_tax, "$.enabled") THEN
                        SET NEW.tax_free = JSON_EXTRACT(NEW.customer_tax, "$.enabled");
                    END IF;
                    IF NEW.company_tax_free <> OLD.company_tax_free THEN
                        SET NEW.company_tax = JSON_OBJECT("enabled", NEW.company_tax_free, "currencyId", JSON_EXTRACT(OLD.company_tax, "$.currencyId"), "amount", JSON_EXTRACT(OLD.company_tax, "$.amount"));
                    ELSEIF NEW.company_tax_free = OLD.company_tax_free AND JSON_EXTRACT(NEW.company_tax, "$.enabled") <> JSON_EXTRACT(OLD.company_tax, "$.enabled") THEN
                        SET NEW.company_tax_free = JSON_EXTRACT(NEW.company_tax, "$.enabled");
                    END IF;
                END IF;
            END$$

DELIMITER ;
SQL

echo "→ Migrationen ausführen..."
ddev exec bin/console database:migrate core --all --quiet
ddev exec bin/console database:migrate Essmann --all --quiet
ddev exec bin/console database:migrate EssmannFAQ --all --quiet

echo "→ Elasticsearch-Index neu aufbauen (Live nutzt ES 7.10.2) — MUSS nach den Migrationen laufen, sonst schlagen Indexing-Jobs auf Spalten fehl, die die Essmann-Migrationen gerade erst angelegt haben..."
ddev exec bin/console es:index
# Indexing-Messages abarbeiten, damit die Suche sofort funktioniert
ddev exec bin/console messenger:consume async --time-limit=30 --memory-limit=512M --quiet || true

if [ "$WITH_CUSTOMER_DATA" -eq 0 ]; then
    echo "→ Kundendaten entfernen (Anfragen, Bestellungen, Kunden, Newsletter-Abonnenten, Gast-Bewertungen, Mail-Archiv – mit --with-customer-data z.B. für Support-/Order-Debugging übernehmen)..."
    ddev exec mysql db <<'SQL'
DELETE FROM essmann_bestprice_request;
DELETE FROM periodrequestform;

DELETE FROM newsletter_recipient;

-- Gast-Bewertungen (kein customer_id) tragen ihre PII direkt in der Zeile (external_user/external_email);
-- Bewertungen mit customer_id werden weiter unten übers Kunden-Delete anonymisiert (customer_id -> NULL)
DELETE FROM product_review WHERE customer_id IS NULL;

-- document.referenced_document_id ist ein Self-FK (Storno-Beleg -> Original-Rechnung); erst entkoppeln, sonst RESTRICT
UPDATE document SET referenced_document_id = NULL;
DELETE FROM document;

-- quote.customer_id ist RESTRICT (nicht CASCADE) -> muss vor customer gelöscht werden
DELETE FROM quote;

-- b2b_components_pending_order.customer_id ist RESTRICT -> muss vor customer gelöscht werden
DELETE FROM b2b_components_pending_order;

DELETE FROM `order`;
DELETE FROM customer;
SQL
else
    echo "→ Kundendaten bleiben erhalten (--with-customer-data)..."
fi

echo "→ EssmannFAQ-Config-Defaults setzen (der manuelle Plugin-Insert oben überspringt plugin:install, das sonst die XML-Defaults einliest – ohne das hier bleiben autoEmbed*/structuredData auf false statt true)..."
ddev exec bin/console system:config:set EssmannFAQ.config.autoEmbedNavigationPages --json 'true' --quiet
ddev exec bin/console system:config:set EssmannFAQ.config.autoEmbedProductPages --json 'true' --quiet
ddev exec bin/console system:config:set EssmannFAQ.config.structuredData --json 'true' --quiet

echo "→ Lokale DooFinder-Config wiederherstellen (Live-Import hat sie eben mit dem Produktions-Account überschrieben)..."
if [ -s "$DOOFINDER_BACKUP" ]; then
    ddev exec mysql db < "$DOOFINDER_BACKUP"
fi
rm -f "$DOOFINDER_BACKUP"

echo "→ DooFinder-App deaktivieren (kein Sync-/Such-Traffic Richtung DooFinder aus ddev)..."
ddev exec bin/console app:deactivate DooFinder --quiet 2>/dev/null || true

echo "→ Anpassungen für lokale Entwicklung..."
ddev exec mysql db -e "
UPDATE system_config
SET configuration_value = '{\"_value\":{\"honeypot\":{\"name\":\"Honeypot\",\"isActive\":true},\"basicCaptcha\":{\"name\":\"basicCaptcha\",\"isActive\":false},\"googleReCaptchaV2\":{\"name\":\"googleReCaptchaV2\",\"isActive\":false,\"config\":{\"siteKey\":\"\",\"secretKey\":\"\",\"invisible\":false}},\"googleReCaptchaV3\":{\"name\":\"googleReCaptchaV3\",\"isActive\":false,\"config\":{\"siteKey\":\"\",\"secretKey\":\"\",\"thresholdScore\":0.5}},\"friendlyCaptcha\":{\"name\":\"friendlyCaptcha\",\"isActive\":false,\"config\":{\"siteKey\":\"\",\"secretKey\":\"\"}}}}'
WHERE configuration_key = 'core.basicInformation.activeCaptchasV2';
"

if ! ddev exec mysql db -se "SELECT 1 FROM user WHERE username = 'admin'" | grep -q 1; then
    ddev exec bin/console user:create admin --password=shopware --admin --no-interaction --quiet
    ddev exec mysql db -e "UPDATE user u JOIN locale l ON l.code = 'de-DE' SET u.locale_id = l.id WHERE u.username = 'admin';"
fi

echo "→ Mailer auf lokales Mailpit umbiegen (sonst gehen Test-Mails über den echten Live-SMTP raus)..."
ddev exec bin/console system:config:set core.mailerSettings --json '{"deliveryAddress":"shop@essmann.com","emailAgent":"smtp","host":"127.0.0.1","port":1025,"username":"","password":"","encryption":null,"senderAddress":"shop@essmann.com","disableDelivery":false,"sendMailOptions":"-t -i"}' --quiet

echo "→ Tracking-Tools deaktivieren (Google Analytics/Ads/Tag Manager, Sendinblue-Tracking)..."
ddev exec bin/console plugin:deactivate DIScoGA4 --quiet 2>/dev/null || true
ddev exec mysql db -e "
UPDATE system_config SET configuration_value = '{\"_value\":false}' WHERE configuration_key = 'Sendinblue.config.isAbandonedCartTrackingEnabled';
UPDATE system_config SET configuration_value = '{\"_value\":false}' WHERE configuration_key = 'Sendinblue.config.isPageTrackingEnabled';
"

echo "→ Cache-Pools nochmal explizit leeren (Redis-backed, überlebt normales cache:clear teils)..."
ddev exec bin/console cache:pool:clear cache.object cache.http cache.tags --quiet 2>/dev/null || true

CUSTOMER_DATA_NOTE="Ohne Kunden-/Bestell-/Anfragedaten."
[ "$WITH_CUSTOMER_DATA" -eq 1 ] && CUSTOMER_DATA_NOTE="Inkl. Kunden-/Bestell-/Anfragedaten (--with-customer-data)."

echo ""
echo "Fertig! Live-Datenbank ist jetzt in ddev aktiv. $CUSTOMER_DATA_NOTE"

mkdir -p "$MARKER_DIR"
printf 'at=%s\nby=%s\nsource=live\ncustomer_data=%s\n' "$(date '+%Y-%m-%d %H:%M')" "$(whoami)" "$WITH_CUSTOMER_DATA" > "$MARKER_DIR/last-sync"
