<?php declare(strict_types=1);

namespace Essmann\DevOps\Command\Shop;

use Essmann\DevOps\Command\OpsCommand;
use Symfony\Component\Console\Attribute\AsCommand;
use Symfony\Component\Console\Command\Command;
use Symfony\Component\Console\Input\InputArgument;
use Symfony\Component\Console\Input\InputInterface;
use Symfony\Component\Console\Input\InputOption;
use Symfony\Component\Console\Output\OutputInterface;
use Symfony\Component\Console\Style\SymfonyStyle;

#[AsCommand(
    name: 'shop:plugins:sync',
    description: 'Fremd-Plugins und Composer-Stand (composer.json/lock) von Live nach Stage oder ddev holen',
)]
final class PluginsSyncCommand extends OpsCommand
{
    protected function configure(): void
    {
        $this
            ->addArgument('target', InputArgument::REQUIRED, 'stage oder ddev')
            ->addOption('dry-run', null, InputOption::VALUE_NONE, 'Nur zeigen, welche Dateien und Pakete sich ändern würden')
            ->setHelp(<<<'HELP'
Plugins werden nur auf Live aktualisiert (Store, Composer). Dieser Befehl zieht den Stand nach:
die unversionierten Plugin-Ordner unter custom/plugins per rsync, dazu composer.json und composer.lock
von Live (Live ist die Composer-Wahrheit), dann composer install und die Cache-Kette.
WebLabels, ShopPlugin und EssmannFaq bleiben auf dem Git-Stand.

Bei ddev ändern sich composer.json und composer.lock im Shop-Repo: danach committen.

  ops shop:plugins:sync ddev --dry-run
  ops shop:plugins:sync stage
HELP);
    }

    protected function execute(InputInterface $input, OutputInterface $output): int
    {
        $io = new SymfonyStyle($input, $output);
        $target = (string) $input->getArgument('target');
        if (!in_array($target, ['stage', 'ddev'], true)) {
            return $this->failure($io, 'Ziel muss stage oder ddev sein.');
        }
        $shop = $this->environments->app('shop');
        $env = $shop->environment($target);
        $live = $shop->environment('live');
        $runner = $this->runner($output);

        $scriptEnv = [
            'ROOT' => $env->isLocal() ? $env->localRoot() : $env->root,
            'PHP' => $env->php,
            'MARKER_DIR' => $env->isLocal() ? $env->localMarkerDir() : $env->markerDir,
            'SOURCE' => $env->isLocal() ? (string) $live->ssh : (string) ($live->sshDirect ?? $live->ssh),
            'SOURCE_ROOT' => $live->root,
            'COMPOSER' => $env->isLocal() ? 'ddev composer' : 'composer',
            'DRY_RUN' => $input->getOption('dry-run') ? '1' : '0',
        ];
        if ($target === 'stage') {
            // Fremd-Plugin-Ordner auf Stage gehören www-data; utime/chmod auf fremden Dateien scheitert sonst (Fund 03.08.2026).
            // Ohne Zeitstempel entscheidet die Prüfsumme, sonst gälte jede Datei bei jedem Lauf als geändert.
            $scriptEnv['RSYNC_FLAGS'] = '--no-perms --no-times --checksum';
        }

        $io->title(sprintf('Fremd-Plugins und Composer Live -> %s%s', $target, $input->getOption('dry-run') ? ' (Trockenlauf)' : ''));
        $rc = $runner->script($env, 'shop/plugins-sync.sh', $scriptEnv, [], true, $target === 'stage');
        if ($rc !== 0) {
            return $this->failure($io, sprintf('Plugin-Sync nach %s ist mit Code %d abgebrochen.', $target, $rc));
        }
        if ($target === 'ddev' && !$input->getOption('dry-run')) {
            $status = $runner->tryCapture('git status --porcelain composer.json composer.lock', $shop->localRepo()) ?? '';
            if (trim($status) !== '') {
                $io->note('composer.json und composer.lock im Shop-Repo haben sich geändert: bitte committen.');
            }
        }

        return Command::SUCCESS;
    }
}
