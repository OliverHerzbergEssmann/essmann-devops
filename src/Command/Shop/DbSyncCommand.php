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
    name: 'shop:db:sync',
    description: 'Shop-Datenbank und Fremd-Plugins von Live nach Stage oder ddev holen (ohne Kundendaten, Konfiguration angepasst)',
)]
final class DbSyncCommand extends OpsCommand
{
    protected function configure(): void
    {
        $this
            ->addArgument('target', InputArgument::REQUIRED, 'stage oder ddev')
            ->addOption('with-customer-data', null, InputOption::VALUE_NONE, 'Kunden, Bestellungen, Anfragen und Newsletter mitnehmen (Support-Fälle)')
            ->addOption('with-live-payment-methods', null, InputOption::VALUE_NONE, 'Nur Stage: PayPal, Mollie und Amazon Pay aktiv lassen')
            ->setHelp(<<<'HELP'
Holt den Live-Stand in die Zielumgebung. Zuerst werden die Fremd-Plugin-Dateien von Live gespiegelt
(WebLabels, ShopPlugin und EssmannFaq bleiben auf dem Git-Stand), dann der Datenbank-Dump importiert.
Danach gilt immer: Captcha aus, URLs der Zielumgebung, Admin-Login admin/shopware, kein Tracking,
Mailer auf Mailpit. Ohne --with-customer-data werden Kunden, Bestellungen, Anfragen, Newsletter-Abonnenten,
Gast-Bewertungen und das Mail-Archiv gelöscht.

  ops shop:db:sync stage
  ops shop:db:sync ddev --with-customer-data
HELP);
    }

    protected function execute(InputInterface $input, OutputInterface $output): int
    {
        $io = new SymfonyStyle($input, $output);
        $target = (string) $input->getArgument('target');
        if (!in_array($target, ['stage', 'ddev'], true)) {
            return $this->failure($io, 'Ziel muss stage oder ddev sein. Live ist nie ein Ziel.');
        }
        $env = $this->environments->app('shop')->environment($target);
        $runner = $this->runner($output);

        $args = [];
        if ($input->getOption('with-customer-data')) {
            $args[] = '--with-customer-data';
        }
        if ($input->getOption('with-live-payment-methods')) {
            if ($target !== 'stage') {
                return $this->failure($io, '--with-live-payment-methods gibt es nur für stage.');
            }
            $args[] = '--with-live-payment-methods';
        }

        $io->title(sprintf('Shop-DB Live -> %s', $target));
        $io->text(sprintf('Ziel: %s (%s). Die Datenbank dort wird ersetzt.', $env->url, $env->isLocal() ? $env->localRoot() : $env->ssh . ':' . $env->root));
        if ($args !== []) {
            $io->text('Optionen: ' . implode(' ', $args));
        }

        $script = $target === 'stage' ? 'shop/db-sync-stage.sh' : 'shop/db-pull-ddev.sh';
        $scriptEnv = ['MARKER_DIR' => $env->isLocal() ? $env->localMarkerDir() : $env->markerDir];
        if ($env->isLocal()) {
            $scriptEnv['DDEV_APPROOT'] = $env->localRoot();
        }

        $rc = $runner->script($env, $script, $scriptEnv, $args, true, $target === 'stage');
        if ($rc !== 0) {
            return $this->failure($io, sprintf('Sync nach %s ist mit Code %d abgebrochen.', $target, $rc));
        }
        $io->success(sprintf('Live-Datenbank ist jetzt auf %s.', $target));

        return Command::SUCCESS;
    }
}
