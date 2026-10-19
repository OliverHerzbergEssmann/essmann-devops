<?php declare(strict_types=1);

namespace Essmann\DevOps\Config;

use Symfony\Component\Yaml\Yaml;

/**
 * Liest config/environments.yaml und stellt die Anwendungen samt Umgebungen bereit.
 */
final class Environments
{
    /** @param array<string, App> $apps */
    private function __construct(private array $apps)
    {
    }

    public static function load(string $path): self
    {
        $data = Yaml::parseFile($path);
        $apps = [];
        foreach ($data as $appName => $appData) {
            $environments = [];
            foreach ($appData['environments'] as $envName => $env) {
                $environments[$envName] = new Environment(
                    app: $appName,
                    name: $envName,
                    kind: $env['kind'],
                    url: $env['url'],
                    root: $env['root'],
                    php: $env['php'],
                    branch: $env['branch'],
                    markerDir: $env['marker_dir'],
                    ssh: $env['ssh'] ?? null,
                    checkout: $env['checkout'] ?? null,
                    gitSshCommand: $env['git_ssh_command'] ?? null,
                    sshDirect: $env['ssh_direct'] ?? null,
                );
                if ($environments[$envName]->isSsh() && $environments[$envName]->ssh === null) {
                    throw new \RuntimeException(sprintf('%s/%s: kind ssh braucht ein Feld ssh (Alias aus ~/.ssh/config).', $appName, $envName));
                }
            }
            $apps[$appName] = new App(
                name: $appName,
                label: $appData['label'] ?? $appName,
                repo: $appData['repo'],
                environments: $environments,
                smoke: $appData['smoke'] ?? [],
            );
        }

        return new self($apps);
    }

    public function app(string $name): App
    {
        if (!isset($this->apps[$name])) {
            throw new \InvalidArgumentException(sprintf('Unbekannte Anwendung "%s". Bekannt: %s', $name, implode(', ', array_keys($this->apps))));
        }

        return $this->apps[$name];
    }

    /** @return array<string, App> */
    public function all(): array
    {
        return $this->apps;
    }

    public static function expandHome(string $path): string
    {
        if (str_starts_with($path, '~/')) {
            return rtrim((string) getenv('HOME'), '/') . substr($path, 1);
        }

        return $path;
    }
}
