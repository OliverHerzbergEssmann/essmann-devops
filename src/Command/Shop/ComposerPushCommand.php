<?php declare(strict_types=1);

namespace Essmann\DevOps\Command\Shop;

use Essmann\DevOps\Command\OpsCommand;
use Essmann\DevOps\Config\Environment;
use Essmann\DevOps\Shell\Runner;
use Essmann\DevOps\Shell\ShellException;
use Symfony\Component\Console\Attribute\AsCommand;
use Symfony\Component\Console\Command\Command;
use Symfony\Component\Console\Input\InputArgument;
use Symfony\Component\Console\Input\InputInterface;
use Symfony\Component\Console\Input\InputOption;
use Symfony\Component\Console\Output\OutputInterface;
use Symfony\Component\Console\Style\SymfonyStyle;

#[AsCommand(
    name: 'shop:composer:push',
    description: 'Composer-Stand aus dem Shop-Repo (composer.json/lock) auf Stage oder Live einspielen, zum Beispiel ein Core-Update',
)]
final class ComposerPushCommand extends OpsCommand
{
    protected function configure(): void
    {
        $this
            ->addArgument('target', InputArgument::REQUIRED, 'stage oder live')
            ->addOption('dry-run', null, InputOption::VALUE_NONE, 'Nur zeigen, welche Pakete sich ändern würden')
            ->addOption('skip-backup', null, InputOption::VALUE_NONE, 'Nur live: kein Live-DB-Backup vorab (nicht empfohlen)')
            ->setHelp(<<<'HELP'
Gegenrichtung zu shop:plugins:sync, für Core-Updates in der Reihenfolge ddev -> Stage -> Live:

  1. ddev:  ddev composer update shopware/core shopware/administration shopware/storefront shopware/elasticsearch --no-scripts
            danach die Kette auf ddev, prüfen, composer.lock committen
  2. Stage: ops shop:composer:push stage, dann die e2e-Suite gegen Stage
  3. Live:  ops shop:composer:push live

Der Befehl lädt composer.json und composer.lock aus dem Shop-Repo hoch und führt auf dem Ziel aus: composer install
(mit oder ohne Dev-Pakete, so wie das Ziel bisher installiert ist), plugin:refresh, cache:clear, Core-Migrationen,
assets:install, theme:compile, cache:clear, Redis-Pools, Opcache-Reset, Smoke-Test. Der alte Composer-Stand wird
auf dem Ziel gesichert. Fremd-Plugin-Ordner bleiben unberührt.

live: nur mit committetem Stand, und nur wenn Stage schon denselben composer.lock hat. Vorher Trockenlauf,
      Rückfrage und Live-DB-Backup.

  ops shop:composer:push stage --dry-run
  ops shop:composer:push stage
  ops shop:composer:push live
HELP);
    }

    protected function execute(InputInterface $input, OutputInterface $output): int
    {
        $io = new SymfonyStyle($input, $output);
        $target = (string) $input->getArgument('target');
        if (!in_array($target, ['stage', 'live'], true)) {
            return $this->failure($io, 'Ziel muss stage oder live sein. ddev wird direkt im Shop-Repo aktualisiert (ddev composer update ...).');
        }
        $dryRun = (bool) $input->getOption('dry-run');
        $shop = $this->environments->app('shop');
        $env = $shop->environment($target);
        $repo = $shop->localRepo();
        $runner = $this->runner($output);

        foreach (['composer.json', 'composer.lock'] as $file) {
            if (!is_file($repo . '/' . $file)) {
                return $this->failure($io, $file . ' fehlt im Shop-Repo.');
            }
        }
        $localHash = substr((string) md5_file($repo . '/composer.lock'), 0, 8);
        $io->title(sprintf('Composer-Stand Shop-Repo -> %s%s', $target, $dryRun ? ' (Trockenlauf)' : ''));
        $io->text(sprintf('composer.lock im Repo: %s (Branch %s)', $localHash, trim($runner->tryCapture('git branch --show-current', $repo) ?? '?')));

        $uncommitted = trim($runner->tryCapture('git status --porcelain composer.json composer.lock', $repo) ?? '') !== '';
        if ($uncommitted) {
            if ($target === 'live' && !$dryRun) {
                return $this->failure($io, 'composer.json oder composer.lock sind im Shop-Repo nicht committet. Live bekommt nur einen committeten Stand.');
            }
            $io->note('composer.json oder composer.lock sind im Shop-Repo noch nicht committet.');
        }

        if ($target === 'live' && !$dryRun) {
            $stage = $shop->environment('stage');
            try {
                $stageHash = substr(trim($runner->captureOn($stage, 'md5sum ' . escapeshellarg($stage->root . '/composer.lock'))), 0, 8);
            } catch (ShellException $e) {
                return $this->failure($io, 'Stand von Stage nicht lesbar: ' . $e->getMessage());
            }
            if ($stageHash !== $localHash) {
                return $this->failure($io, sprintf('Stage hat composer.lock %s, das Repo %s. Erst "ops shop:composer:push stage" und dort testen.', $stageHash, $localHash));
            }
            $io->text('Stage läuft schon mit diesem composer.lock.');

            // Erst zeigen, was sich auf Live ändert, dann fragen.
            if ($this->push($runner, $env, $repo, $shop->smoke, true) !== 0) {
                return $this->failure($io, 'Trockenlauf auf Live fehlgeschlagen, nichts geändert.');
            }
            if (!$io->confirm('Diesen Composer-Stand auf LIVE einspielen?', false)) {
                $io->text('Abgebrochen, nichts passiert.');

                return Command::SUCCESS;
            }
            if (!$input->getOption('skip-backup')) {
                $io->section('Live-DB-Backup (bleibt auf Live und im Shop-Repo unter var/)');
                if ($runner->script($shop->environment('ddev'), 'shop/live-db-backup.sh', ['LOCAL_DIR' => $repo . '/var'], [], false) !== 0) {
                    return $this->failure($io, 'Live-DB-Backup fehlgeschlagen, nichts geändert.');
                }
            }
        }

        $rc = $this->push($runner, $env, $repo, $shop->smoke, $dryRun);
        if ($rc === 2) {
            $io->warning('Composer-Stand eingespielt, aber der Smoke-Test hat Befunde. Bitte die Seite prüfen, Rückweg siehe Ausgabe.');

            return Command::FAILURE;
        }
        if ($rc !== 0) {
            return $this->failure($io, sprintf('Abgebrochen mit Code %d. Siehe Ausgabe: bis zum Opcache-Reset läuft die Storefront mit dem alten Bytecode.', $rc));
        }
        if (!$dryRun) {
            $io->success($target === 'stage'
                ? 'Stage hat den Composer-Stand aus dem Repo. Jetzt die e2e-Suite gegen Stage, danach "ops shop:composer:push live".'
                : 'Live hat den Composer-Stand aus dem Repo. Smoke-Test im Browser: Startseite, PDP, Listing, Checkout bis Zahlart, Admin.');
        }

        return Command::SUCCESS;
    }

    /**
     * composer.json und composer.lock hochladen und das Skript auf dem Ziel starten. Das Skript löscht die
     * hochgeladenen Dateien selbst, deshalb vor jedem Lauf (Trockenlauf und echter Lauf) neu hochladen.
     *
     * @param array<string, mixed> $smoke
     */
    private function push(Runner $runner, Environment $env, string $repo, array $smoke, bool $dryRun): int
    {
        $remote = '/tmp/essmann-ops-composer-' . getmypid();
        foreach (['json', 'lock'] as $ext) {
            $upload = sprintf('ssh %s %s < %s', escapeshellarg((string) $env->ssh), escapeshellarg('cat > ' . $remote . '.' . $ext), escapeshellarg($repo . '/composer.' . $ext));
            if ($runner->local($upload) !== 0) {
                throw new ShellException('Upload von composer.' . $ext . ' nach ' . $env->ssh . ' fehlgeschlagen.');
            }
        }
        $scriptEnv = $this->scriptEnv($env) + [
            'NEW_JSON' => $remote . '.json',
            'NEW_LOCK' => $remote . '.lock',
            'DRY_RUN' => $dryRun ? '1' : '0',
            // Stage hat public/clear_cache.php dauerhaft, Live bekommt wie im Deploy eine Datei nur für den Reset.
            'OPCACHE' => $env->name === 'stage' ? 'clear_cache' : 'temp_file',
            'SMOKE_LISTING_PATH' => (string) ($smoke['listing_path'] ?? '/'),
        ];

        return $runner->script($env, 'shop/composer-push.sh', $scriptEnv, [], true);
    }
}
