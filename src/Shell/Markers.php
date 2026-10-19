<?php declare(strict_types=1);

namespace Essmann\DevOps\Shell;

use Essmann\DevOps\Config\Environment;

/**
 * Marker-Dateien: jede Umgebung merkt sich in <marker_dir>/<name> als key=value-Zeilen, wann sie zuletzt
 * deployt oder synchronisiert wurde. Die Skripte schreiben sie, der Status liest sie.
 */
final class Markers
{
    public function __construct(private readonly Runner $runner)
    {
    }

    /** @return array<string, string> */
    public function read(Environment $env, string $name): array
    {
        $command = sprintf('cat %s/%s 2>/dev/null || true', $env->isLocal() ? escapeshellarg($env->localMarkerDir()) : $env->markerDir, $name);
        $raw = $this->runner->tryCapture($env->isLocal() ? $command : $command, null, 20) ?? '';

        return self::parse($raw);
    }

    /** @return array<string, string> */
    public static function parse(string $raw): array
    {
        $values = [];
        foreach (preg_split('/\R/', trim($raw)) ?: [] as $line) {
            if (str_contains($line, '=')) {
                [$key, $value] = explode('=', $line, 2);
                $values[trim($key)] = trim($value);
            }
        }

        return $values;
    }
}
