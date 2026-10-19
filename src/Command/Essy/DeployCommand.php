<?php declare(strict_types=1);

namespace Essmann\DevOps\Command\Essy;

use Essmann\DevOps\Command\OpsCommand;
use Symfony\Component\Console\Attribute\AsCommand;
use Symfony\Component\Console\Command\Command;
use Symfony\Component\Console\Input\InputArgument;
use Symfony\Component\Console\Input\InputInterface;
use Symfony\Component\Console\Input\InputOption;
use Symfony\Component\Console\Output\OutputInterface;
use Symfony\Component\Console\Style\SymfonyStyle;

#[AsCommand(
    name: 'essy:deploy',
    description: 'ESSY (kern-poc) auf den Server deployen: main holen, Dateien kopieren, Composer, Backup, Migrationen, Cache, Web-Test',
)]
final class DeployCommand extends OpsCommand
{
    protected function configure(): void
    {
        $this
            ->addArgument('target', InputArgument::OPTIONAL, 'prod', 'prod')
            ->addOption('force', null, InputOption::VALUE_NONE, 'Auch deployen, wenn der Stand laut Marker schon läuft')
            ->setHelp(<<<'HELP'
Deployt den Stand von origin/main in die laufende Installation auf dem Server. Lokale, nicht gepushte
Commits gehen nicht mit: erst pushen. Vor den Migrationen wird die Konfiguration geprüft und die
SQLite-Datenbank gesichert (app:db:backup --label=before-deploy).

  ops essy:deploy
  ops essy:deploy --force
HELP);
    }

    protected function execute(InputInterface $input, OutputInterface $output): int
    {
        $io = new SymfonyStyle($input, $output);
        $target = (string) $input->getArgument('target');
        if ($target !== 'prod') {
            return $this->failure($io, 'ESSY hat nur das Ziel prod (dev ist ddev auf dem Mac).');
        }
        $essy = $this->environments->app('essy');
        $env = $essy->environment('prod');
        $runner = $this->runner($output);
        $repo = $essy->localRepo();

        $io->title('ESSY -> Produktion');
        $runner->capture('git fetch origin --quiet', $repo);
        $unpushed = trim($runner->tryCapture('git log --oneline origin/main..main', $repo) ?? '');
        if ($unpushed !== '') {
            $io->warning("Lokale Commits, die nicht in origin/main sind und deshalb nicht mitgehen:\n" . $unpushed);
        }
        $head = trim($runner->capture('git log -1 --format="%h %cs %s" origin/main', $repo));
        $io->text('origin/main: ' . $head);

        $rc = $runner->script($env, 'essy/deploy-prod.sh', $this->scriptEnv($env) + ['FORCE' => $input->getOption('force') ? '1' : '0'], [], true);
        if ($rc === 2) {
            $io->warning('Deployt, aber der Web-Test ist fehlgeschlagen.');

            return Command::FAILURE;
        }
        if ($rc !== 0) {
            return $this->failure($io, sprintf('ESSY-Deploy ist mit Code %d abgebrochen.', $rc));
        }
        $io->success('ESSY deployt.');

        return Command::SUCCESS;
    }
}
