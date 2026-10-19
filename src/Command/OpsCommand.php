<?php declare(strict_types=1);

namespace Essmann\DevOps\Command;

use Essmann\DevOps\Config\Environment;
use Essmann\DevOps\Config\Environments;
use Essmann\DevOps\Shell\Runner;
use Symfony\Component\Console\Command\Command;
use Symfony\Component\Console\Output\OutputInterface;
use Symfony\Component\Console\Style\SymfonyStyle;

/**
 * Gemeinsame Basis: Zugriff auf die Umgebungen und einen Runner für die Ausgabe des Aufrufs.
 */
abstract class OpsCommand extends Command
{
    public function __construct(protected readonly Environments $environments)
    {
        parent::__construct();
    }

    protected function runner(OutputInterface $output): Runner
    {
        return new Runner($output, dirname(__DIR__, 2) . '/scripts');
    }

    /** @return array<string, string> Umgebungsvariablen, die jedes Server-Skript bekommt */
    protected function scriptEnv(Environment $env): array
    {
        $vars = [
            'ROOT' => $env->root,
            'PHP' => $env->php,
            'BRANCH' => $env->branch,
            'URL' => $env->url,
            'MARKER_DIR' => $env->isLocal() ? $env->localMarkerDir() : $env->markerDir,
        ];
        if ($env->checkout !== null) {
            $vars['CHECKOUT'] = $env->checkout;
        }
        if ($env->gitSshCommand !== null) {
            $vars['GIT_SSH_COMMAND'] = $env->gitSshCommand;
        }

        return $vars;
    }

    protected function failure(SymfonyStyle $io, string $message): int
    {
        $io->error($message);

        return Command::FAILURE;
    }
}
