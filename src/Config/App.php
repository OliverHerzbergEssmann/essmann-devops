<?php declare(strict_types=1);

namespace Essmann\DevOps\Config;

final readonly class App
{
    /**
     * @param array<string, Environment> $environments
     * @param array<string, mixed> $smoke
     */
    public function __construct(
        public string $name,
        public string $label,
        public string $repo,
        public array $environments,
        public array $smoke = [],
    ) {
    }

    public function localRepo(): string
    {
        return Environments::expandHome($this->repo);
    }

    public function environment(string $name): Environment
    {
        if (!isset($this->environments[$name])) {
            throw new \InvalidArgumentException(sprintf(
                'Unbekannte Umgebung "%s" für %s. Bekannt: %s',
                $name,
                $this->name,
                implode(', ', array_keys($this->environments)),
            ));
        }

        return $this->environments[$name];
    }
}
