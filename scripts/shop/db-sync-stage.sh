#!/usr/bin/env bash
#
# DB-Sync Live -> Stage. Läuft AUF dem Stage-Server (herzberg), gestartet per `ops shop:db:sync stage`,
# das diese Datei bei jedem Aufruf hochlädt. Nichts mehr nach /usr/local/bin kopieren.
#
# Standardmäßig ohne Kunden-/Bestell-/Anfragedaten; --with-customer-data übernimmt alles (Support-Fälle).
# PayPal/Mollie/Amazon Pay werden deaktiviert (Stage hat keine Sandboxen); --with-live-payment-methods lässt sie an.
# Danach gilt immer: Captcha aus, URLs umgeschrieben, admin/shopware vorhanden, kein Tracking, Mailer auf Mailpit.
#
# Voraussetzung: SSH-Agent-Forwarding (Stage -> Live läuft mit dem Mac-Key).
#
MARKER_DIR="${MARKER_DIR:-$HOME/.essmann-ops/shop}"
set -e
trap 'rm -f "$DUMP_FILE" "$CLEAN_FILE"' EXIT

WITH_CUSTOMER_DATA=0
WITH_LIVE_PAYMENT_METHODS=0
for arg in "$@"; do
    case "$arg" in
        --with-customer-data)
            WITH_CUSTOMER_DATA=1
            ;;
        --with-live-payment-methods)
            WITH_LIVE_PAYMENT_METHODS=1
            ;;
        *)
            echo "Unbekannter Parameter: $arg" >&2
            echo "Usage: db-sync [--with-customer-data] [--with-live-payment-methods]" >&2
            exit 1
            ;;
    esac
done

PROD_HOST="s8.weblabels-server.de"
PROD_USER="hw_waegetech_essmann_ssh"
PROD_SHOPWARE="/var/www/clients/client80/web225/web"
STAGE_SHOPWARE="/var/www/shopware"
PROD_URL="https://www.essmann-shop.com"
STAGE_URL="http://essmann-shop.essmann.intern"
DUMP_FILE="/tmp/prod_dump_$(date +%Y%m%d_%H%M%S).sql"
CLEAN_FILE="${DUMP_FILE%.sql}_clean.sql"

echo "--- DB-Sync von Prod -> Stage ---"

# Muss vor dem DB-Import laufen: sonst kann der Container an Plugin-Klassen scheitern, die die
# frisch importierte Live-DB referenziert, es auf Stage aber noch nicht gibt. WebLabels/ShopPlugin/
# EssmannFaq sind versioniert und bleiben bewusst auf main-Stand, nicht auf Live-Stand (analog zu
# .ddev/commands/host/db-pull).
echo "[1/15] Fremd-Plugin-Dateien von Prod spiegeln (nicht versioniert, sonst driften sie auseinander)..."
# --no-perms --no-times: Fremd-Plugin-Ordner gehoeren www-data, db-sync laeuft aber als
# herzberg ohne sudo -> Inhalte lassen sich schreiben, aber utime/chmod auf fremden Dateien
# scheitert mit "Operation not permitted" und bricht das ganze Script per set -e ab (Fund
# 2026-08-03). Zeitstempel/Rechte sind hier ohnehin irrelevant, nur der Inhalt zaehlt.
rsync -a --no-perms --no-times --delete \
  --exclude=WebLabels --exclude=ShopPlugin --exclude=EssmannFaq \
  --exclude=.DS_Store --exclude=.gitignore --exclude=.gitkeep \
  --exclude=webla_zusatzoptionen.zip \
  -e ssh \
  "$PROD_USER@$PROD_HOST:$PROD_SHOPWARE/custom/plugins/" \
  "$STAGE_SHOPWARE/custom/plugins/"

echo "[2/15] Stage Credentials laden..."
STAGE_DB_URL=$(grep DATABASE_URL $STAGE_SHOPWARE/.env.local | cut -d'=' -f2- | tr -d '"')
STAGE_DB_USER=$(echo "$STAGE_DB_URL" | sed 's|mysql://||' | cut -d':' -f1)
STAGE_DB_PASS=$(echo "$STAGE_DB_URL" | sed 's|mysql://[^:]*:||' | cut -d'@' -f1)
STAGE_DB_HOST=$(echo "$STAGE_DB_URL" | cut -d'@' -f2 | cut -d':' -f1)
STAGE_DB_NAME=$(echo "$STAGE_DB_URL" | cut -d'/' -f4 | cut -d'?' -f1)

echo "[3/15] Dump von Prod ziehen (komprimiert)..."
ssh "$PROD_USER@$PROD_HOST" bash << 'ENDSSH' | gzip -d > "$DUMP_FILE"
DB_URL=$(grep DATABASE_URL /var/www/clients/client80/web225/web/.env.local | cut -d'=' -f2- | tr -d '"')
DB_USER=$(echo "$DB_URL" | sed 's|mysql://||' | cut -d':' -f1)
DB_PASS=$(echo "$DB_URL" | sed 's|mysql://[^:]*:||' | cut -d'@' -f1)
DB_HOST=$(echo "$DB_URL" | cut -d'@' -f2 | cut -d':' -f1)
DB_NAME=$(echo "$DB_URL" | cut -d'/' -f4 | cut -d'?' -f1)

printf "[client]\nhost=%s\nuser=%s\npassword=%s\n" "$DB_HOST" "$DB_USER" "$DB_PASS" > /tmp/.my_sync.cnf

mysqldump --defaults-file=/tmp/.my_sync.cnf \
  --single-transaction --quick --lock-tables=false \
  $DB_NAME | gzip

rm /tmp/.my_sync.cnf
ENDSSH

echo "[3/15] Dump-Groesse: $(du -sh $DUMP_FILE | cut -f1)"

echo "[4/15] Dump bereinigen..."
sed \
  -e 's/^ALTER DATABASE.*//' \
  -e 's/\/\*!50017 DEFINER=`[^`]*`@`[^`]*`\*\/ //' \
  "$DUMP_FILE" > "$CLEAN_FILE"

echo "[5/15] Stage DB leeren und importieren..."
mysql -h "$STAGE_DB_HOST" -u "$STAGE_DB_USER" -p"$STAGE_DB_PASS" \
  -e "DROP DATABASE IF EXISTS $STAGE_DB_NAME; CREATE DATABASE $STAGE_DB_NAME CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;"

mysql -h "$STAGE_DB_HOST" -u "$STAGE_DB_USER" -p"$STAGE_DB_PASS" \
  "$STAGE_DB_NAME" < "$CLEAN_FILE"

echo "[6/15] URLs anpassen..."
mysql -h "$STAGE_DB_HOST" -u "$STAGE_DB_USER" -p"$STAGE_DB_PASS" "$STAGE_DB_NAME" << SQLEOF
UPDATE sales_channel_domain SET url = REPLACE(url, '$PROD_URL', '$STAGE_URL');
UPDATE system_config SET configuration_value = REPLACE(configuration_value, '$PROD_URL', '$STAGE_URL')
  WHERE configuration_key LIKE '%domain%' OR configuration_key LIKE '%url%' OR configuration_key LIKE '%host%';
UPDATE seo_url SET is_modified = 0;
SQLEOF

if [ "$WITH_LIVE_PAYMENT_METHODS" -eq 0 ]; then
  echo "[7/15] PayPal/Mollie/Amazon Pay deaktivieren (verhindert eine versehentliche echte Zahlung - mit --with-live-payment-methods aktiv lassen)..."
  mysql -h "$STAGE_DB_HOST" -u "$STAGE_DB_USER" -p"$STAGE_DB_PASS" "$STAGE_DB_NAME" \
    -e "UPDATE payment_method SET active = 0 WHERE handler_identifier LIKE '%PayPal%' OR handler_identifier LIKE '%Mollie%' OR handler_identifier LIKE '%Amazon%';"
else
  echo "[7/15] PayPal/Mollie/Amazon Pay bleiben aktiv (--with-live-payment-methods) - vermutlich ohne Sandbox, siehe DEPLOYMENT.md..."
fi

echo "[8/15] Migrationen ausfuehren..."
cd $STAGE_SHOPWARE
sudo -u www-data php bin/console database:migrate core --all --quiet
sudo -u www-data php bin/console database:migrate Essmann --all --quiet

if [ "$WITH_CUSTOMER_DATA" -eq 0 ]; then
  echo "[9/15] Kundendaten entfernen (Anfragen, Bestellungen, Kunden, Newsletter-Abonnenten, Gast-Bewertungen, Mail-Archiv – mit --with-customer-data z.B. fuer Support-Faelle uebernehmen)..."
  mysql -h "$STAGE_DB_HOST" -u "$STAGE_DB_USER" -p"$STAGE_DB_PASS" "$STAGE_DB_NAME" << 'SQLEOF'
DELETE FROM essmann_bestprice_request;
DELETE FROM periodrequestform;

DELETE FROM newsletter_recipient;

-- Gast-Bewertungen (kein customer_id) tragen ihre PII direkt in der Zeile (external_user/external_email);
-- Bewertungen mit customer_id werden weiter unten uebers Kunden-Delete anonymisiert (customer_id -> NULL)
DELETE FROM product_review WHERE customer_id IS NULL;

-- document.referenced_document_id ist ein Self-FK (Storno-Beleg -> Original-Rechnung); erst entkoppeln, sonst RESTRICT
UPDATE document SET referenced_document_id = NULL;
DELETE FROM document;

-- quote.customer_id ist RESTRICT (nicht CASCADE) -> muss vor customer geloescht werden
DELETE FROM quote;

-- b2b_components_pending_order.customer_id ist RESTRICT -> muss vor customer geloescht werden
DELETE FROM b2b_components_pending_order;

DELETE FROM `order`;
DELETE FROM customer;
SQLEOF
else
  echo "[9/15] Kundendaten bleiben erhalten (--with-customer-data)..."
fi

echo "[10/15] reCAPTCHA deaktivieren..."
CAPTCHA_JSON='{"_value":{"honeypot":{"name":"Honeypot","isActive":true},"basicCaptcha":{"name":"basicCaptcha","isActive":false},"googleReCaptchaV2":{"name":"googleReCaptchaV2","isActive":false,"config":{"siteKey":"","secretKey":"","invisible":false}},"googleReCaptchaV3":{"name":"googleReCaptchaV3","isActive":false,"config":{"siteKey":"","secretKey":"","thresholdScore":0.5}},"friendlyCaptcha":{"name":"friendlyCaptcha","isActive":false,"config":{"siteKey":"","secretKey":""}}}}'
mysql -h "$STAGE_DB_HOST" -u "$STAGE_DB_USER" -p"$STAGE_DB_PASS" "$STAGE_DB_NAME" \
  -e "UPDATE system_config SET configuration_value = '$CAPTCHA_JSON' WHERE configuration_key = 'core.basicInformation.activeCaptchasV2';"

echo "[11/15] Mailer auf lokales Mailpit umbiegen (sonst gehen Test-Mails ueber den echten Live-SMTP raus)..."
cd $STAGE_SHOPWARE
sudo -u www-data php bin/console system:config:set core.mailerSettings --json '{"deliveryAddress":"shop@essmann.com","emailAgent":"smtp","host":"127.0.0.1","port":1025,"username":"","password":"","encryption":null,"senderAddress":"shop@essmann.com","disableDelivery":false,"sendMailOptions":"-t -i"}' --quiet

echo "[12/15] Tracking-Tools deaktivieren (Google Analytics/Ads/Tag Manager, Sendinblue-Tracking)..."
sudo -u www-data php bin/console plugin:deactivate DIScoGA4 --quiet || true
mysql -h "$STAGE_DB_HOST" -u "$STAGE_DB_USER" -p"$STAGE_DB_PASS" "$STAGE_DB_NAME" -e "
UPDATE system_config SET configuration_value = '{\"_value\":false}' WHERE configuration_key = 'Sendinblue.config.isAbandonedCartTrackingEnabled';
UPDATE system_config SET configuration_value = '{\"_value\":false}' WHERE configuration_key = 'Sendinblue.config.isPageTrackingEnabled';
"

echo "[13/15] Admin-Login anlegen (admin/shopware) falls noch nicht vorhanden..."
if ! mysql -h "$STAGE_DB_HOST" -u "$STAGE_DB_USER" -p"$STAGE_DB_PASS" "$STAGE_DB_NAME" -se "SELECT 1 FROM user WHERE username = 'admin'" | grep -q 1; then
  sudo -u www-data php bin/console user:create admin --password=shopware --admin --no-interaction --quiet
  mysql -h "$STAGE_DB_HOST" -u "$STAGE_DB_USER" -p"$STAGE_DB_PASS" "$STAGE_DB_NAME" \
    -e "UPDATE user u JOIN locale l ON l.code = 'de-DE' SET u.locale_id = l.id WHERE u.username = 'admin';"
fi

echo "[14/15] Cache leeren (inkl. Redis-backed Pools), dann Theme kompilieren..."
# WICHTIG: theme:compile MUSS der letzte Schritt sein. Es legt einen Seed im
# Redis-Cache ab, aus dem der Storefront-Request den Theme-Pfad-Hash berechnet.
# Ein cache:clear DANACH loescht den Seed -> die Seite fordert einen nie
# kompilierten Hash an -> 503 auf all.css/js. Daher: erst clear, dann compile.
cd $STAGE_SHOPWARE
sudo -u www-data php bin/console cache:clear
sudo -u www-data php bin/console cache:pool:clear cache.object cache.http cache.tags || true
sudo -u www-data php bin/console theme:compile --active-only

echo "[15/15] Dumps aufraumen..."
rm "$DUMP_FILE" "$CLEAN_FILE"

echo ""
echo "DONE: DB-Sync fertig!"
CUSTOMER_DATA_NOTE="Ohne Kunden-/Bestell-/Anfragedaten."
[ "$WITH_CUSTOMER_DATA" -eq 1 ] && CUSTOMER_DATA_NOTE="Inkl. Kunden-/Bestell-/Anfragedaten (--with-customer-data)."
PAYMENT_METHODS_NOTE="PayPal, Mollie und Amazon Pay wurden deaktiviert."
[ "$WITH_LIVE_PAYMENT_METHODS" -eq 1 ] && PAYMENT_METHODS_NOTE="PayPal, Mollie und Amazon Pay bleiben aktiv (--with-live-payment-methods, vermutlich ohne Sandbox)."
echo "HINWEIS: $CUSTOMER_DATA_NOTE $PAYMENT_METHODS_NOTE Google Analytics/Ads/Tag Manager und Sendinblue-Tracking sind aus. Mailer zeigt auf Mailpit (Port 8025)."

mkdir -p "$MARKER_DIR"
printf 'at=%s\nby=%s\nsource=live\ncustomer_data=%s\n' "$(date '+%Y-%m-%d %H:%M')" "$(whoami)" "$WITH_CUSTOMER_DATA" > "$MARKER_DIR/last-sync"
