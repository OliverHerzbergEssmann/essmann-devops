<?php declare(strict_types=1);

namespace Essmann\DevOps\Shell;

use Essmann\DevOps\Config\Environment;
use Symfony\Component\Console\Output\OutputInterface;
use Symfony\Component\Process\Process;

/**
 * Führt Befehle lokal oder per SSH aus. Skripte aus scripts/ werden nicht auf den Servern installiert,
 * sondern bei jedem Aufruf hochgeladen und ausgeführt: das Repo ist die einzige Quelle.
 */
final class Runner
{
    public function __construct(
        private readonly OutputInterface $output,
        private readonly string $scriptsDir,
    ) {
    }

    /** Lokaler Befehl mit durchgereichter Ausgabe. Liefert den Exit-Code. */
    public function local(string $command, ?string $cwd = null, array $env = [], bool $tty = false): int
    {
        $this->trace($command, $cwd);
        $process = Process::fromShellCommandline($command, $cwd, $env + $this->baseEnv(), null, null);
        if ($tty && Process::isTtySupported()) {
            $process->setTty(true);
            $process->run();
        } else {
            $process->run(fn (string $type, string $buffer) => $this->output->write($buffer));
        }

        return $process->getExitCode() ?? 1;
    }

    /** Lokaler Befehl, dessen Ausgabe zurückgegeben wird. Wirft bei Fehler. */
    public function capture(string $command, ?string $cwd = null, array $env = [], int $timeout = 60): string
    {
        $process = Process::fromShellCommandline($command, $cwd, $env + $this->baseEnv(), null, $timeout);
        $process->run();
        if (!$process->isSuccessful()) {
            throw new ShellException(sprintf("Befehl fehlgeschlagen (%d): %s\n%s", $process->getExitCode(), $command, trim($process->getErrorOutput())));
        }

        return $process->getOutput();
    }

    /** Lokaler Befehl, dessen Ausgabe zurückgegeben wird; bei Fehler null statt Exception. */
    public function tryCapture(string $command, ?string $cwd = null, int $timeout = 60): ?string
    {
        try {
            return $this->capture($command, $cwd, [], $timeout);
        } catch (ShellException) {
            return null;
        }
    }

    /** Befehl auf dem Zielsystem der Umgebung (lokal oder per SSH) mit durchgereichter Ausgabe. */
    public function on(Environment $env, string $command, bool $tty = false, bool $forwardAgent = false): int
    {
        if ($env->isLocal()) {
            return $this->local($command, $env->localRoot(), [], $tty);
        }

        return $this->local($this->sshCommand($env, $command, $tty, $forwardAgent), null, [], $tty);
    }

    /** Befehl auf dem Zielsystem, Ausgabe zurück. */
    public function captureOn(Environment $env, string $command, int $timeout = 60): string
    {
        if ($env->isLocal()) {
            return $this->capture($command, $env->localRoot(), [], $timeout);
        }

        return $this->capture($this->sshCommand($env, $command, false, false), null, [], $timeout);
    }

    /**
     * Ein Skript aus scripts/ auf dem Zielsystem ausführen: hochladen nach /tmp, mit Umgebungsvariablen
     * und Argumenten starten, danach löschen. Lokal läuft es direkt aus dem Repo.
     *
     * @param array<string, string> $env Umgebungsvariablen für das Skript
     * @param list<string> $args
     */
    public function script(Environment $target, string $script, array $env = [], array $args = [], bool $tty = true, bool $forwardAgent = false): int
    {
        $path = $this->scriptsDir . '/' . $script;
        if (!is_file($path)) {
            throw new ShellException('Skript fehlt: ' . $path);
        }
        $envPrefix = $this->envPrefix($env);
        $argString = implode(' ', array_map('escapeshellarg', $args));

        if ($target->isLocal()) {
            return $this->local(trim($envPrefix . ' bash ' . escapeshellarg($path) . ' ' . $argString), $target->localRoot(), [], $tty);
        }

        $remote = '/tmp/essmann-ops-' . basename($script, '.sh') . '-' . getmypid() . '.sh';
        $upload = sprintf('ssh %s %s < %s', escapeshellarg($target->ssh), escapeshellarg('cat > ' . $remote), escapeshellarg($path));
        if ($this->local($upload) !== 0) {
            throw new ShellException('Upload des Skripts nach ' . $target->ssh . ' fehlgeschlagen.');
        }
        $run = sprintf('%sbash %s %s; rc=$?; rm -f %s; exit $rc', $envPrefix, $remote, $argString, $remote);

        return $this->local($this->sshCommand($target, $run, $tty, $forwardAgent), null, [], $tty);
    }

    /**
     * Wie script(), aber die Ausgabe wird zurückgegeben statt durchgereicht (für Probes). Wirft bei Fehler.
     *
     * @param array<string, string> $env
     */
    public function scriptCapture(Environment $target, string $script, array $env = [], int $timeout = 60): string
    {
        $path = $this->scriptsDir . '/' . $script;
        if (!is_file($path)) {
            throw new ShellException('Skript fehlt: ' . $path);
        }
        $envPrefix = $this->envPrefix($env);
        if ($target->isLocal()) {
            return $this->capture(trim($envPrefix . ' bash ' . escapeshellarg($path)), $target->localRoot(), [], $timeout);
        }
        // Skript über stdin an eine entfernte bash: ein Aufruf, kein Upload. Die Probes lesen stdin nicht.
        $command = sprintf('ssh -o BatchMode=yes -o ConnectTimeout=10 %s %s < %s', escapeshellarg((string) $target->ssh), escapeshellarg($envPrefix . 'bash -s'), escapeshellarg($path));

        return $this->capture($command, null, [], $timeout);
    }

    /**
     * KEY='wert' KEY2="$HOME"'/rest' ... : ein führendes ~ wird auf dem Zielsystem über $HOME aufgelöst,
     * weil ein in Anführungszeichen übergebenes ~ sonst wörtlich stehen bliebe.
     *
     * @param array<string, string> $env
     */
    private function envPrefix(array $env): string
    {
        $prefix = '';
        foreach ($env as $key => $value) {
            if ($value === '~' || str_starts_with($value, '~/')) {
                $prefix .= $key . '="$HOME"' . escapeshellarg(substr($value, 1)) . ' ';
            } else {
                $prefix .= $key . '=' . escapeshellarg($value) . ' ';
            }
        }

        return $prefix;
    }

    private function sshCommand(Environment $env, string $command, bool $tty, bool $forwardAgent): string
    {
        $flags = '-o BatchMode=yes';
        if ($tty && Process::isTtySupported()) {
            $flags = '-t';
        }
        if ($forwardAgent) {
            $flags .= ' -A';
        }

        return sprintf('ssh %s %s %s', $flags, escapeshellarg((string) $env->ssh), escapeshellarg($command));
    }

    private function trace(string $command, ?string $cwd): void
    {
        if ($this->output->isVerbose()) {
            $this->output->writeln(sprintf('<comment>$ %s%s</comment>', $cwd ? '(cd ' . $cwd . ') ' : '', $command));
        }
    }

    /** @return array<string, string> */
    private function baseEnv(): array
    {
        return ['HOME' => (string) getenv('HOME'), 'PATH' => (string) getenv('PATH'), 'SSH_AUTH_SOCK' => (string) getenv('SSH_AUTH_SOCK'), 'TERM' => (string) (getenv('TERM') ?: 'xterm-256color')];
    }
}
