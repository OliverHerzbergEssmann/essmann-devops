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
    name: 'shop:cleanup',
    description: 'Alte Logfiles, alte Exporte und den alten Google-Feed auf ddev, Stage oder Live löschen',
)]
final class CleanupCommand extends OpsCommand
{
    protected function configure(): void
    {
        $this
            ->addArgument('target', InputArgument::REQUIRED, 'ddev, stage oder live')
            ->addOption('days', null, InputOption::VALUE_REQUIRED, 'Dateien, die älter sind als so viele Tage, gelten als alt', '7')
            ->addOption('feed-pattern', null, InputOption::VALUE_REQUIRED, 'Namensmuster des alten Google-Feeds in files/export (ohne Beachtung der Groß-/Kleinschreibung)', '*google*')
            ->addOption('dry-run', null, InputOption::VALUE_NONE, 'Nur zeigen, was gelöscht würde')
            ->addOption('yes', 'y', InputOption::VALUE_NONE, 'Ohne Rückfrage löschen (stage und live fragen sonst nach dem Trockenlauf)')
            ->setHelp(<<<'HELP'
Löscht auf dem Ziel:
  - files/export: Dateien, die dem Feed-Muster entsprechen (Google-Feed) und älter als --days sind
  - files/export: alle übrigen Dateien, die älter als --days sind
  - var/log: *.log* älter als --days
  - Shopware-Importe/-Exporte mit abgelaufener Aufbewahrung (bin/console import-export:delete-expired)

Alt heißt: Änderungszeit älter als --days Tage. Der aktuelle Google-Feed bleibt dadurch stehen, weil ihn der
Cronjob des Produktexports täglich neu schreibt. Auf stage und live läuft zuerst ein Trockenlauf, dann fragt
der Befehl nach. Einen Marker `last-cleanup` gibt es nur nach einem echten Lauf.

  ops shop:cleanup ddev
  ops shop:cleanup live --dry-run
  ops shop:cleanup stage --days=14 --yes
HELP);
    }

    protected function execute(InputInterface $input, OutputInterface $output): int
    {
        $io = new SymfonyStyle($input, $output);
        $target = (string) $input->getArgument('target');
        if (!in_array($target, ['ddev', 'stage', 'live'], true)) {
            return $this->failure($io, 'Ziel muss ddev, stage oder live sein.');
        }
        $days = (string) $input->getOption('days');
        if (!ctype_digit($days) || (int) $days < 1) {
            return $this->failure($io, '--days muss eine ganze Zahl ab 1 sein.');
        }

        $env = $this->environments->app('shop')->environment($target);
        $runner = $this->runner($output);
        $scriptEnv = [
            'ROOT' => $env->isLocal() ? $env->localRoot() : $env->root,
            'PHP' => $env->php,
            'MARKER_DIR' => $env->isLocal() ? $env->localMarkerDir() : $env->markerDir,
            'DAYS' => $days,
            'FEED_PATTERN' => (string) $input->getOption('feed-pattern'),
        ];

        $io->title(sprintf('Aufräumen auf %s (älter als %s Tage)', $target, $days));
        $rc = $runner->script($env, 'shop/cleanup.sh', $scriptEnv + ['DRY_RUN' => '1'], [], false);
        if ($rc !== 0) {
            return $this->failure($io, sprintf('Trockenlauf auf %s ist mit Code %d abgebrochen.', $target, $rc));
        }
        if ($input->getOption('dry-run')) {
            return Command::SUCCESS;
        }
        $needsConfirm = $target !== 'ddev' && !$input->getOption('yes');
        if ($needsConfirm && !$io->confirm(sprintf('Das oben Genannte auf %s wirklich löschen?', $target), false)) {
            $io->warning('Abgebrochen, nichts gelöscht.');

            return Command::SUCCESS;
        }

        $rc = $runner->script($env, 'shop/cleanup.sh', $scriptEnv + ['DRY_RUN' => '0'], [], false);
        if ($rc !== 0) {
            return $this->failure($io, sprintf('Aufräumen auf %s ist mit Code %d abgebrochen.', $target, $rc));
        }

        return Command::SUCCESS;
    }
}
