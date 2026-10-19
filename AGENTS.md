# essmann-devops: Hinweise für Agenten und Entwickler

Stand 19.10.2026. Dieses Dokument ist Regelwerk und Gedächtnis des Repos zugleich. Wer etwas ändert, zieht den Abschnitt
„Gedächtnis“ am Ende im selben Commit nach: ein Eintrag mit Datum, was sich geändert hat und warum. Entscheidungen des Users
stehen mit Datum unter „Entscheidungen“ und werden nicht stillschweigend umgedeutet.

## Was das hier ist

`ops` ist die DevOps-Konsole für zwei Anwendungen: den **ESSMANN Shop** (Shopware 6.6, Repo `essmann-shop`, Umgebungen ddev,
Stage, Live) und **ESSY** (Symfony 7.4, Repo `kern-poc`, Umgebungen dev in ddev und Produktion). Sie läuft auf dem Mac
(PHP 8.3, Symfony Console) und steuert die Server per SSH über die Aliasse `stage` und `prod` aus `~/.ssh/config`.
Befehle und Einrichtung: [README.md](README.md). Warum die Server-Abläufe so sind, wie sie sind (Cache-Schichten, Opcache,
Reihenfolgen, Vorfälle): `essmann-shop/DEPLOYMENT.md` und `kern-poc/docs/DEPLOYMENT.md`. Diese beiden Dokumente sind die
Begründung, dieses Repo ist die Ausführung.

## Regeln

1. **Live ist nie Ziel eines Syncs.** Ziele für `shop:db:sync` und `shop:plugins:sync` sind Stage und ddev. Der Code prüft das, trotzdem gilt es auch beim Erweitern.
2. **Kein Deploy auf Live oder Stage ohne Auftrag des Users im Chat.** Ein Deploy ist ein Eingriff in eine laufende Umgebung. Für ESSY gilt dasselbe: `essy:deploy` schreibt in die Produktion. Trockenläufe (`--dry-run`) und `ops status` sind lesend und jederzeit erlaubt.
3. **Kein Commit ohne Freigabe des Users.** Commits englisch, einzeilig, Conventional Commits (`feat:`, `fix:`, `docs:`, `chore:`), keine KI-Erwähnung, kein Co-Authored-By.
4. **Keine Zugangsdaten im Repo.** Datenbank-Zugänge lesen die Skripte auf dem Zielsystem aus dessen `.env.local`. Interne Hostnamen stehen in `config/environments.yaml`, das reicht; nichts davon ins Forum oder in Chats außerhalb der Arbeit.
5. **Server-Skripte werden nicht installiert, sondern bei jedem Aufruf hochgeladen** (`Runner::script()` legt sie unter `/tmp/essmann-ops-*.sh` ab und löscht sie danach). Nichts mehr nach `/usr/local/bin` kopieren, keine Kopien auf den Servern pflegen. Das alte `/usr/local/bin/deploy-stage` auf Stage ist tot und bleibt, weil es root gehört.
6. **Jeder Deploy und Sync schreibt einen Marker** (`~/.essmann-ops/<app>/last-deploy|last-sync|last-plugins`, key=value) im Home des Deploy-Benutzers auf dem jeweiligen System. `ops status` liest sie. Ein neuer Befehl, der eine Umgebung verändert, schreibt auch einen.
7. **Bestehende Einstiege bleiben funktionsfähig:** `./deploy-stage.sh`, `./db-sync.sh`, `./live-db-backup.sh` und `ddev db-pull` im Shop-Repo sind Wrapper auf `ops`. Wer einen Befehl umbenennt, zieht die Wrapper nach.
8. **Ausgaben und Doku auf Deutsch, Bezeichner im Code englisch.** Bindestriche statt Gedankenstriche, keine Emojis.
9. **Ändern heißt dokumentieren:** README (Befehle), dieses Dokument (Regeln, Fallen, Gedächtnis) und, wenn sich ein Server-Ablauf ändert, auch `essmann-shop/DEPLOYMENT.md`.

## Aufbau

```
bin/ops                        Einstieg, registriert die Commands
config/environments.yaml       Anwendungen, Umgebungen, Pfade, Benutzer, Smoke-Test-Pfade
src/Config/                    Environments (YAML-Loader), App, Environment
src/Shell/Runner.php           local(), capture(), on(), script(), scriptCapture(); SSH-Aufbau, ~ wird über $HOME aufgelöst
src/Shell/Markers.php          Marker lesen und parsen
src/Status/Collector.php       sammelt Probe, HTTP-Prüfung und Git-Abstände je Umgebung
src/Command/OpsCommand.php     Basis: Runner, scriptEnv() (ROOT, PHP, BRANCH, URL, MARKER_DIR, CHECKOUT, GIT_SSH_COMMAND)
src/Command/StatusCommand.php  ops status
src/Command/Shop/              DbSyncCommand, PluginsSyncCommand, DeployCommand (stage und live)
src/Command/Essy/              DeployCommand
scripts/shop/probe.sh          liest Zustand (key=value), ändert nichts
scripts/shop/db-sync-stage.sh  läuft auf Stage; Inhalt = das frühere db-sync.sh des Shop-Repos
scripts/shop/db-pull-ddev.sh   läuft auf dem Mac; Inhalt = das frühere .ddev/commands/host/db-pull
scripts/shop/plugins-sync.sh   läuft auf dem Ziel: rsync der Fremd-Plugins, composer.json/lock von Live, composer install, Cache-Kette
scripts/shop/deploy-stage.sh   läuft auf Stage: git pull + submodule, rsync der drei eigenen Plugins, composer, Migrationen, Cache-Kette, Opcache
scripts/shop/deploy-live.sh    läuft auf Live: Ablauf aus DEPLOYMENT.md mit Plugin-Tarball, Cache-Kette, Opcache-Schleife, Smoke-Test
scripts/shop/live-db-backup.sh läuft auf dem Mac: retiniertes Live-Backup (bleibt auf Live und lokal unter var/ des Shop-Repos)
scripts/essy/probe.sh          liest Zustand von ESSY
scripts/essy/deploy-prod.sh    läuft auf dem Server: Dateien, composer --no-dev, Umgebungsprüfung, Sicherung, Migrationen, Assets, Cache, Web-Test
```

Die Skripte sind eigenständig lauffähige Bash-Dateien mit `set -euo pipefail`, bekommen ihre Werte als Umgebungsvariablen
und haben sinnvolle Vorgaben, damit sie auch von Hand auf dem Server laufen. Sie lesen nie stdin (bei `scriptCapture()`
kommt das Skript selbst über stdin).

## Umgebungen

| Anwendung | Umgebung | Wo | Deploy-Benutzer | Console |
|---|---|---|---|---|
| Shop | ddev | `~/code/essmann-shop`, `https://essmann-shop.ddev.site` | Mac | `ddev exec bin/console` |
| Shop | stage | Checkout `/home/herzberg/monorepo` (Branch `stage`), Docroot `/var/www/shopware` | `herzberg` | `sudo -u www-data php bin/console` (passwortlos erlaubt) |
| Shop | live | Checkout `~/essmann-shop-release` (Branch `release`), Docroot der Hosting-Umgebung | Shell-User `web225`, Git mit eigenem GitHub-Key (`git_ssh_command`) | `php bin/console` |
| ESSY | dev | `~/code/kern-poc`, `https://kern-poc.ddev.site` | Mac | `ddev exec bin/console` |
| ESSY | prod | Checkout `/home/herzberg/kern-poc` (Branch `main`), Installation `/var/www/kern-poc` auf dem Stage-Host | `herzberg`, Dateien gehören ihm, `var/` und `public/assets` gehören `www-data` | `sudo -u www-data php bin/console` |

Stage, Live und ddev haben eigenständige `composer.json`/`composer.lock`/`vendor` (kein Git auf den Servern). Fremd-Plugins
kommen teils per Composer (B2B, webla_zusatzoptionen, Frosh), teils als Ordner unter `custom/plugins`; `shop:plugins:sync` holt beides von Live.

## Fallen, die schon zugeschlagen haben

- **`$` in PHP-Schnipseln verschwindet hinter `ddev exec`:** ddev reicht die Argumente durch eine zweite Shell. Dateien lesen die Probes deshalb mit dem PHP der Shell (`php -r`), nur `PHP_VERSION` und Zugriffe auf `var/` laufen über `$PHP`, und diese Schnipsel kommen ohne `$`-Variablen aus.
- **`~` in per SSH übergebenen Werten bleibt wörtlich:** `KEY='~/x'` wird nicht aufgelöst. `Runner::envPrefix()` macht daraus `KEY="$HOME"'/x'`. Lokale Pfade löst `Environments::expandHome()` auf.
- **Fremd-Plugin-Ordner auf Stage gehören www-data:** rsync als `herzberg` scheitert an `utime`/`chmod`. Daher `--no-perms --no-times --checksum` (ohne `--checksum` gälte ohne Zeitabgleich jede Datei bei jedem Lauf als geändert).
- **ESSY: `assets/vendor` und `public/assets` im Ziel gehören www-data:** `rsync -a` scheitert an `chgrp` und `utime`. `deploy-prod.sh` kopiert mit `rsync -rl --checksum` und lässt `public/assets` aus (das baut `asset-map:compile` als www-data).
- **sudo auf dem Stage-Host hat `use_pty`:** Befehle laufen ohne Terminal trotzdem, aber nur die in den Sudoers erlaubten (`/usr/bin/php` als www-data, dazu `bin/console` beider Anwendungen). Alles andere fragt nach einem Passwort und bricht in Skripten ab.
- **Der pre-push-Hook auf `release` liest von /dev/tty:** `shop:deploy live` pusht mit `setTty(true)`. Ohne Terminal (zum Beispiel aus einem Agenten heraus) schlägt der Push fehl; dann pusht der User selbst und ruft `ops shop:deploy live --skip-merge` auf.
- **`database:migrate --all Essmann` findet neue Migrationen bei gleicher Plugin-Version nicht immer** (Fund 07/2026). Beide Deploy-Skripte vergleichen die ShopPlugin-Version vor und nach dem rsync und rufen bei einem Sprung `plugin:update Essmann` auf. `shop:deploy live` verweigert, wenn `composer.json` des Plugins und die Kopfzeile des CHANGELOG nicht dieselbe Version nennen.
- **Drei Cache-Schichten auf Stage und Live:** Symfony-Cache, Redis-Pools (`cache.object`, `cache.http`, `cache.tags`) und der PHP-Opcache je FPM-Worker. Die Deploy-Skripte leeren alle drei, den Opcache mit 30 Aufrufen. Reihenfolge und Vorfälle: `essmann-shop/DEPLOYMENT.md`.
- **`theme:compile` muss nach `cache:clear` laufen,** sonst 503 auf `all.css`. Siehe Shop-Memory und DEPLOYMENT.md.

## Entscheidungen

- **19.10.2026, Olli:** Eigenes Repo mit Symfony-Console-App statt Commands im ShopPlugin (der Branch `feature/dev-ops` vom 20.07.2026 im Shop-Repo hatte das; Ideen übernommen, Code nicht) und statt Makefile.
- **19.10.2026, Olli:** Live ist die Composer-Wahrheit. `shop:plugins:sync` holt `composer.json` und `composer.lock` von Live; bei ddev landen sie im Shop-Repo und werden committed.
- **19.10.2026, Olli:** Der Live-Deploy behält den pre-push-Hook auf `release`; der User bestätigt den Push mit `yes`. `ops` zeigt vorher die Commit-Liste `origin/release..origin/stage`.
- **19.10.2026, Annahme (von Olli nicht widersprochen):** ESSY bleibt im heutigen Aufbau unter `/var/www/kern-poc`. Der Aufbau mit Release-Ordnern, eigenem Benutzer und Rollback aus `kern-poc/bin/deploy.sh` wartet auf die Einrichtung durch die IT; `essy:deploy` wird dann auf dieses Skript umgestellt.
- **19.10.2026:** Keine e2e-Tests aus `ops` heraus. Die volle Suite läuft vor dem Release-Merge von Hand (Repo `e2e`, `npm run cy:stage`), Stage-Deploys laufen ohne Tests.

## Offen

- `db-sync-stage.sh` und `db-pull-ddev.sh` zusammenführen (rund 70 Prozent gleich, nur Zielsystem und Aufrufe unterscheiden sich).
- Rollback-Befehl für den Shop auf Live (das Plugin-Tarball liegt vor, der Rückweg ist nur in der Ausgabe beschrieben).
- Web-Dashboard aus `ops status --json`.
- Erstlauf von `shop:db:sync` und `shop:deploy live` über `ops` (die Sync-Skripte sind inhaltlich die alten, der Live-Deploy ist neu geschrieben und noch nie gelaufen).

## Gedächtnis

Ein Eintrag je Änderung, neueste oben: Datum, was, warum. Längere Begründungen in den Abschnitten oben, hier nur der Verweis.
Das Forum (Bereich `gedaechtnis`, Thread „[essmann-devops] ops-Konsole: Entscheidungen und Stand“) führt den Stand sitzungsübergreifend.

- **19.10.2026:** Repo angelegt, `ops` mit `status`, `shop:db:sync`, `shop:plugins:sync`, `shop:deploy stage|live`, `essy:deploy`. Die vier Skripte im Shop-Repo zu Wrappern gemacht, DEPLOYMENT.md verweist auf `ops`. Geprüft gegen echte Umgebungen: `status` (11 s für fünf Umgebungen), beide Plugin-Sync-Trockenläufe, `shop:deploy stage` und `essy:deploy` mit Freigabe des Users. Dabei gefunden und behoben: `$`-Verlust hinter `ddev exec`, `~` per SSH, rsync-Flags für www-data-Ordner auf Stage und bei ESSY (siehe „Fallen“).
