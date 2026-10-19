# essmann-devops

`ops` ist die DevOps-Konsole für den ESSMANN Shop (Shopware 6.6, Repo `essmann-shop`) und ESSY (Symfony, Repo `kern-poc`).
Sie läuft auf dem Mac und steuert Stage und Live per SSH. Die Server-Skripte liegen hier unter `scripts/` und werden
bei jedem Aufruf hochgeladen und ausgeführt: nichts wird mehr nach `/usr/local/bin` kopiert, dieses Repo ist die einzige Quelle.

## Einrichtung

```bash
cd ~/code/essmann-devops
composer install
ln -sf ~/code/essmann-devops/bin/ops /opt/homebrew/bin/ops   # optional, dann reicht `ops`
```

Voraussetzungen: PHP 8.3 und Composer auf dem Mac, die SSH-Aliasse `stage` und `prod` aus `~/.ssh/config`
(mit Agent-Forwarding für `stage`), VPN für Stage, ddev-Projekte `essmann-shop` und `kern-poc`.
Keine Zugangsdaten in diesem Repo: Datenbank-Zugänge liest jedes Skript auf dem Zielsystem aus dessen `.env.local`.

## Befehle

| Befehl | Was passiert |
|---|---|
| `ops status` | Zustand aller Umgebungen: HTTP, Shopware/Symfony-Version, PHP, ShopPlugin, composer.lock, Checkout, letzter Deploy, letzter DB-Sync, letzter Plugin-Sync, Branch-Abstände. `--watch=30`, `--json`, `--app=shop` |
| `ops shop:db:sync stage\|ddev` | Live-DB und Fremd-Plugins ins Ziel. Ohne Kundendaten, Captcha aus, URLs umgeschrieben, admin/shopware, kein Tracking, Mailer auf Mailpit. `--with-customer-data`, `--with-live-payment-methods` (nur stage) |
| `ops shop:plugins:sync stage\|ddev` | Fremd-Plugin-Ordner per rsync und `composer.json`/`composer.lock` von Live (Live ist die Composer-Wahrheit), dann `composer install` und Cache-Kette. `--dry-run` zeigt Datei- und Paket-Unterschiede |
| `ops shop:deploy stage` | main nach stage mergen und pushen, auf Stage: Plugins inkl. EssmannFaq-Submodule, composer install, Migrationen (bei neuer Plugin-Version `plugin:update`), Cache-Kette, Opcache. Keine Tests |
| `ops shop:deploy live` | Zeigt die Commits `origin/release..origin/stage`, prüft ShopPlugin-Version gegen CHANGELOG, fragt nach, pusht release (pre-push-Hook fragt `yes`), Live-DB-Backup, dann auf Live der Ablauf aus DEPLOYMENT.md mit Plugin-Backup, Cache-Kette, Opcache und Smoke-Test. `--skip-merge`, `--with-category-content` |
| `ops essy:deploy` | origin/main auf den Server: Dateien kopieren, `composer install --no-dev`, Konfiguration prüfen, DB sichern, Migrationen, Assets, Cache, Web-Test auf `/login`. `--force` |

Jeder Deploy und Sync schreibt eine Marker-Datei (`~/.essmann-ops/<app>/last-deploy`, `last-sync`, `last-plugins`)
im Home des Deploy-Benutzers auf dem jeweiligen System. `ops status` liest sie. Umgebungen, Pfade und Benutzer
stehen in `config/environments.yaml`.

## Was wo läuft

- **Shop Stage:** Checkout `/home/herzberg/monorepo` (Branch `stage`), Docroot `/var/www/shopware`, Console als `www-data` per sudo.
- **Shop Live:** Checkout `~/essmann-shop-release` (Branch `release`), Docroot der Hosting-Umgebung, Git über den GitHub-Key des Servers.
- **ESSY Produktion:** läuft auf dem Stage-Host unter `/var/www/kern-poc`, Code gehört `herzberg`, `var/` gehört `www-data`.
  Der Aufbau mit Release-Ordnern und eigenem Benutzer aus `kern-poc/bin/deploy.sh` wartet auf die Einrichtung durch die IT;
  bis dahin deployt `ops essy:deploy` in die laufende Installation.

## Regeln

- Live ist nie Ziel eines Syncs. Ziele sind Stage und ddev.
- Kein Zwischen-Deploy auf Stage: erst in ddev testen, Stage in einem Rutsch. Die volle e2e-Suite läuft vor dem Release-Merge (Repo `e2e`, `npm run cy:stage`), nicht automatisch.
- `release` hat im Shop-Repo einen pre-push-Hook, der mit `yes` bestätigt werden will. `ops shop:deploy live` lässt ihn bewusst stehen.
- Was die einzelnen Schritte warum tun (Cache-Schichten, Opcache, Reihenfolge), steht in `essmann-shop/DEPLOYMENT.md`.
