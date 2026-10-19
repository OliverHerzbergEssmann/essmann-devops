<?php declare(strict_types=1);

namespace Essmann\DevOps\Command\Shop;

use Essmann\DevOps\Command\OpsCommand;
use Essmann\DevOps\Config\App;
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
    name: 'shop:deploy',
    description: 'Shop auf Stage (main -> stage) oder Live (stage -> release) deployen',
)]
final class DeployCommand extends OpsCommand
{
    protected function configure(): void
    {
        $this
            ->addArgument('target', InputArgument::REQUIRED, 'stage oder live')
            ->addOption('skip-merge', null, InputOption::VALUE_NONE, 'Branch nicht mergen und pushen, nur den Server-Teil ausführen')
            ->addOption('skip-backup', null, InputOption::VALUE_NONE, 'Nur live: kein Live-DB-Backup vorab (nicht empfohlen)')
            ->addOption('with-category-content', null, InputOption::VALUE_NONE, 'Nur live: Kategorie-Inhalte und FAQ neu importieren (DEPLOYMENT.md Schritt 9)')
            ->setHelp(<<<'HELP'
stage: merged main nach stage, pusht, und führt auf dem Stage-Server den Deploy aus (Plugins per rsync
       inkl. EssmannFaq-Submodule, composer install, Migrationen, Cache-Kette, Opcache). Keine e2e-Tests.
live:  zeigt, welche Commits live gehen (origin/release..origin/stage), prüft die ShopPlugin-Version gegen den
       CHANGELOG, fragt nach, setzt release auf stage und pusht (der pre-push-Hook fragt noch einmal mit "yes"),
       zieht das Live-DB-Backup und führt auf Live den Ablauf aus DEPLOYMENT.md aus, mit Plugin-Backup,
       Cache-Kette, Opcache-Reset und Smoke-Test. Die volle e2e-Suite gegen Stage ist vorher Handarbeit.

  ops shop:deploy stage
  ops shop:deploy live
  ops shop:deploy live --skip-merge        # release ist schon gepusht
HELP);
    }

    protected function execute(InputInterface $input, OutputInterface $output): int
    {
        $io = new SymfonyStyle($input, $output);
        $target = (string) $input->getArgument('target');
        if (!in_array($target, ['stage', 'live'], true)) {
            return $this->failure($io, 'Ziel muss stage oder live sein.');
        }
        $shop = $this->environments->app('shop');
        $runner = $this->runner($output);

        return $target === 'stage'
            ? $this->deployStage($io, $runner, $shop, (bool) $input->getOption('skip-merge'))
            : $this->deployLive($io, $runner, $shop, $input);
    }

    private function deployStage(SymfonyStyle $io, Runner $runner, App $shop, bool $skipMerge): int
    {
        $env = $shop->environment('stage');
        $repo = $shop->localRepo();
        $io->title('Shop -> Stage');

        if (!$skipMerge) {
            $runner->capture('git fetch origin --quiet', $repo);
            $pending = trim($runner->capture('git log --no-merges --oneline origin/stage..main', $repo));
            if ($pending === '') {
                $io->text('main hat nichts, was nicht schon auf stage ist.');
            } else {
                $io->section('Geht neu auf Stage (main, noch nicht in origin/stage)');
                $io->writeln($pending);
            }
            if ($this->mergeAndPush($io, $runner, $repo, 'main', 'stage') !== 0) {
                return Command::FAILURE;
            }
        }

        $io->section('Deploy auf dem Stage-Server');
        $rc = $runner->script($env, 'shop/deploy-stage.sh', $this->scriptEnv($env), [], true);
        if ($rc !== 0) {
            return $this->failure($io, sprintf('Stage-Deploy ist mit Code %d abgebrochen.', $rc));
        }
        $io->success('Stage deployt (ohne Tests). Passende Specs bei Bedarf gezielt laufen lassen.');

        return Command::SUCCESS;
    }

    private function deployLive(SymfonyStyle $io, Runner $runner, App $shop, InputInterface $input): int
    {
        $env = $shop->environment('live');
        $repo = $shop->localRepo();
        $io->title('Shop -> LIVE');
        $runner->capture('git fetch origin --quiet', $repo);

        if (!$input->getOption('skip-merge')) {
            $pending = trim($runner->capture('git log --no-merges --oneline origin/release..origin/stage', $repo));
            $notOnStage = trim($runner->capture('git log --no-merges --oneline origin/stage..origin/main', $repo));
            if ($pending === '') {
                $io->text('origin/release steht schon auf dem Stand von origin/stage.');
            } else {
                $io->section('Geht LIVE (origin/stage, noch nicht in origin/release)');
                $io->writeln($pending);
                $io->text(sprintf('%d Commit(s).', substr_count($pending, "\n") + 1));
            }
            if ($notOnStage !== '') {
                $io->note("Nicht dabei, weil noch nicht auf stage:\n" . $notOnStage);
            }

            $version = $this->versionCheck($io, $runner, $repo, 'origin/stage');
            if ($version === null) {
                return Command::FAILURE;
            }
            $io->text('ShopPlugin-Version auf stage: ' . $version);

            if (!$io->confirm('Diesen Stand live bringen? (release auf stage setzen und pushen)', false)) {
                $io->text('Abgebrochen, nichts passiert.');

                return Command::SUCCESS;
            }
            if ($pending !== '' && $this->mergeAndPush($io, $runner, $repo, 'origin/stage', 'release') !== 0) {
                return Command::FAILURE;
            }
        } elseif (!$io->confirm('Ohne Merge: den Stand von origin/release jetzt auf Live deployen?', false)) {
            return Command::SUCCESS;
        }

        if (!$input->getOption('skip-backup')) {
            $io->section('Live-DB-Backup (bleibt auf Live und im Shop-Repo unter var/)');
            $rc = $runner->script($shop->environment('ddev'), 'shop/live-db-backup.sh', ['LOCAL_DIR' => $repo . '/var'], [], false);
            if ($rc !== 0) {
                return $this->failure($io, 'Live-DB-Backup fehlgeschlagen, Deploy abgebrochen.');
            }
        }

        $io->section('Deploy auf dem Live-Server');
        $scriptEnv = $this->scriptEnv($env) + [
            'WITH_CATEGORY_CONTENT' => $input->getOption('with-category-content') ? '1' : '0',
            'SMOKE_LISTING_PATH' => (string) ($shop->smoke['listing_path'] ?? '/'),
            'SMOKE_PRODUCT_PATH' => (string) ($shop->smoke['product_path'] ?? ''),
        ];
        $rc = $runner->script($env, 'shop/deploy-live.sh', $scriptEnv, [], true);
        if ($rc === 2) {
            $io->warning('Live deployt, aber der Smoke-Test hat Befunde. Bitte die Seite prüfen, Rückweg siehe Ausgabe.');

            return Command::FAILURE;
        }
        if ($rc !== 0) {
            return $this->failure($io, sprintf('Live-Deploy ist mit Code %d abgebrochen. Live läuft, bis zum Rsync, auf dem alten Stand; danach hilft das Plugin-Backup.', $rc));
        }
        $io->success('Live deployt. Smoke-Test im Browser: Startseite, PDP (2 ld+json), Listing, Checkout bis Zahlart.');

        return Command::SUCCESS;
    }

    /**
     * $from nach $to mergen und pushen, ohne den Arbeitsbaum anzufassen, wenn es ein Fast-Forward ist.
     * Sonst klassisch: sauberer Baum, checkout, merge, push, zurück.
     */
    private function mergeAndPush(SymfonyStyle $io, Runner $runner, string $repo, string $from, string $to): int
    {
        $current = trim($runner->capture('git branch --show-current', $repo));
        $isAncestor = $runner->tryCapture(sprintf('git merge-base --is-ancestor origin/%s %s && echo yes', $to, $from), $repo);
        if ($current !== $to && trim((string) $isAncestor) === 'yes') {
            $io->text(sprintf('%s -> %s ist ein Fast-Forward, kein Checkout nötig.', $from, $to));
            $rc = $runner->local(sprintf('git push origin %s:refs/heads/%s', $from, $to), $repo, [], true);
            if ($rc === 0) {
                $runner->tryCapture(sprintf('git branch -f %s origin/%s', $to, $to), $repo);
            }

            return $rc === 0 ? 0 : $this->failure($io, 'Push abgebrochen oder fehlgeschlagen.');
        }

        if (trim($runner->capture('git status --porcelain', $repo)) !== '') {
            return $this->failure($io, 'Arbeitsbaum im Shop-Repo ist nicht sauber und der Merge braucht einen Checkout: erst committen oder stashen.');
        }
        $steps = [
            sprintf('git checkout %s', $to),
            sprintf('git merge %s --no-edit', $from),
            sprintf('git push origin %s', $to),
        ];
        foreach ($steps as $step) {
            if ($runner->local($step, $repo, [], true) !== 0) {
                $runner->local(sprintf('git checkout %s', $current), $repo);

                return $this->failure($io, 'Fehlgeschlagen: ' . $step);
            }
        }
        if ($current !== '' && $current !== $to) {
            $runner->local(sprintf('git checkout %s', $current), $repo);
        }

        return 0;
    }

    /** Version aus custom/plugins/ShopPlugin/composer.json auf $ref, geprüft gegen die Kopfzeile des CHANGELOG. */
    private function versionCheck(SymfonyStyle $io, Runner $runner, string $repo, string $ref): ?string
    {
        try {
            $composer = $runner->capture(sprintf('git show %s:custom/plugins/ShopPlugin/composer.json', $ref), $repo);
            $changelog = $runner->capture(sprintf('git show %s:custom/plugins/ShopPlugin/CHANGELOG.md', $ref), $repo);
        } catch (ShellException $e) {
            $this->failure($io, $e->getMessage());

            return null;
        }
        $version = (string) (json_decode($composer, true)['version'] ?? '');
        preg_match('/^#\s*([0-9]+\.[0-9]+\.[0-9]+)/m', $changelog, $m);
        $changelogVersion = $m[1] ?? '';
        if ($version === '' || $changelogVersion === '') {
            $this->failure($io, 'ShopPlugin-Version oder CHANGELOG-Kopfzeile nicht lesbar.');

            return null;
        }
        if ($version !== $changelogVersion) {
            $this->failure($io, sprintf('ShopPlugin composer.json sagt %s, der CHANGELOG-Kopf %s. Vor dem Release die Version in composer.json hochsetzen und auf stage bringen.', $version, $changelogVersion));

            return null;
        }

        return $version;
    }
}
