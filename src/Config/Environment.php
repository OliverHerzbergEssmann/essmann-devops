<?php declare(strict_types=1);

namespace Essmann\DevOps\Config;

/**
 * Eine Umgebung einer Anwendung (zum Beispiel shop/stage), so wie config/environments.yaml sie beschreibt.
 */
final readonly class Environment
{
    public function __construct(
        public string $app,
        public string $name,
        public string $kind,
        public string $url,
        public string $root,
        public string $php,
        public string $branch,
        public string $markerDir,
        public ?string $ssh = null,
        public ?string $checkout = null,
        public ?string $gitSshCommand = null,
        public ?string $sshDirect = null,
    ) {
    }

    public function id(): string
    {
        return $this->app . '/' . $this->name;
    }

    public function isLocal(): bool
    {
        return $this->kind === 'local';
    }

    public function isSsh(): bool
    {
        return $this->kind === 'ssh';
    }

    public function console(): string
    {
        return $this->php . ' bin/console';
    }

    /** Lokale Pfade mit ~ auflösen; entfernte Pfade bleiben, dort löst die Shell ~ selbst auf. */
    public function localRoot(): string
    {
        return Environments::expandHome($this->root);
    }

    public function localMarkerDir(): string
    {
        return Environments::expandHome($this->markerDir);
    }
}
