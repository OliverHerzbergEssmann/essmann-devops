<?php declare(strict_types=1);

namespace Essmann\DevOps\Status;

use Essmann\DevOps\Config\App;
use Essmann\DevOps\Config\Environment;
use Essmann\DevOps\Config\Environments;
use Essmann\DevOps\Shell\Markers;
use Essmann\DevOps\Shell\Runner;
use Essmann\DevOps\Shell\ShellException;

/**
 * Sammelt je Umgebung die Probe-Werte (per Skript auf dem Zielsystem), die HTTP-Prüfung vom Mac aus
 * und für den Shop die Branch-Abstände aus dem lokalen Repo. Liest nur, ändert nichts.
 */
final class Collector
{
    public function __construct(
        private readonly Environments $environments,
        private readonly Runner $runner,
    ) {
    }

    /** @return array<string, array{app: App, environments: array<string, array<string, string>>, git: array<string, string>}> */
    public function collect(?string $onlyApp = null, bool $fetch = true): array
    {
        $result = [];
        foreach ($this->environments->all() as $name => $app) {
            if ($onlyApp !== null && $onlyApp !== $name) {
                continue;
            }
            $envs = [];
            foreach ($app->environments as $envName => $env) {
                $envs[$envName] = $this->probe($app, $env) + $this->http($app, $env);
            }
            $result[$name] = ['app' => $app, 'environments' => $envs, 'git' => $this->git($app, $fetch)];
        }

        return $result;
    }

    /** @return array<string, string> */
    private function probe(App $app, Environment $env): array
    {
        $vars = [
            'ROOT' => $env->isLocal() ? $env->localRoot() : $env->root,
            'PHP' => $env->php,
            'MARKER_DIR' => $env->isLocal() ? $env->localMarkerDir() : $env->markerDir,
        ];
        if ($env->checkout !== null) {
            $vars['CHECKOUT'] = $env->checkout;
        } elseif ($env->isLocal()) {
            $vars['CHECKOUT'] = $env->localRoot();
        }
        try {
            $raw = $this->runner->scriptCapture($env, $app->name . '/probe.sh', $vars, 40);
        } catch (ShellException $e) {
            return ['error' => $this->shortError($e->getMessage())];
        }

        return Markers::parse($raw);
    }

    /** @return array<string, string> */
    private function http(App $app, Environment $env): array
    {
        $path = $app->name === 'essy' ? '/login' : '/';
        $out = $this->runner->tryCapture(sprintf('curl -sk --max-time 12 -w %s %s', escapeshellarg("\n__code=%{http_code}"), escapeshellarg(rtrim($env->url, '/') . $path)), null, 20) ?? "\n__code=000";
        $pos = strrpos($out, "\n__code=");
        $code = $pos === false ? '000' : trim(substr($out, $pos + 8));
        $body = $pos === false ? '' : substr($out, 0, $pos);
        $data = ['http' => $code];
        if ($app->name === 'shop' && preg_match('/all\.css\?(\d{9,})/', $body, $m)) {
            $data['theme_compiled'] = date('Y-m-d H:i', (int) $m[1]);
        }
        if ($app->name === 'essy') {
            $data['title_ok'] = str_contains($body, 'ESSY</title>') ? 'ja' : 'nein';
        }

        return $data;
    }

    /** @return array<string, string> */
    private function git(App $app, bool $fetch): array
    {
        $repo = $app->localRepo();
        if (!is_dir($repo . '/.git')) {
            return [];
        }
        if ($fetch) {
            $this->runner->tryCapture('git fetch origin --quiet', $repo, 40);
        }
        $count = fn (string $range): string => trim($this->runner->tryCapture('git rev-list --no-merges --count ' . $range, $repo) ?? '?');
        $data = [
            'local_branch' => trim($this->runner->tryCapture('git branch --show-current', $repo) ?? ''),
            'local_dirty' => trim($this->runner->tryCapture('git status --porcelain | wc -l', $repo) ?? '?'),
            'local_unpushed' => $count('origin/main..main'),
        ];
        if ($app->name === 'shop') {
            $data['main_not_on_stage'] = $count('origin/stage..origin/main');
            $data['stage_not_on_release'] = $count('origin/release..origin/stage');
            $data['main_not_on_release'] = $count('origin/release..origin/main');
            $data['stage_only'] = $count('origin/main..origin/stage');
        }

        return $data;
    }

    private function shortError(string $message): string
    {
        $lines = array_values(array_filter(array_map('trim', preg_split('/\R/', $message) ?: [])));

        return $lines[count($lines) - 1] ?? 'Fehler';
    }
}
