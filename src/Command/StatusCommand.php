<?php declare(strict_types=1);

namespace Essmann\DevOps\Command;

use Essmann\DevOps\Status\Collector;
use Symfony\Component\Console\Attribute\AsCommand;
use Symfony\Component\Console\Command\Command;
use Symfony\Component\Console\Helper\Table;
use Symfony\Component\Console\Input\InputInterface;
use Symfony\Component\Console\Input\InputOption;
use Symfony\Component\Console\Output\BufferedOutput;
use Symfony\Component\Console\Output\OutputInterface;

#[AsCommand(
    name: 'status',
    description: 'Zustand aller Umgebungen: Erreichbarkeit, Versionen, deployter Stand, letzter Sync, Branch-Abstände',
)]
final class StatusCommand extends OpsCommand
{
    private const SHOP_ROWS = [
        'http' => 'Erreichbar (HTTP)',
        'shopware' => 'Shopware',
        'php' => 'PHP',
        'plugin' => 'ShopPlugin',
        'lock' => 'composer.lock',
        'foreign_plugins' => 'Fremd-Plugins',
        'checkout' => 'Checkout',
        'deploy' => 'Letzter Deploy',
        'theme_compiled' => 'Theme kompiliert',
        'sync' => 'Letzter DB-Sync',
        'plugins' => 'Letzter Plugin-Sync',
    ];

    private const ESSY_ROWS = [
        'http' => 'Erreichbar (/login)',
        'symfony' => 'Symfony',
        'php' => 'PHP',
        'lock' => 'composer.lock',
        'checkout' => 'Checkout',
        'deploy' => 'Letzter Deploy',
        'last_backup' => 'Letzte DB-Sicherung',
        'db_size' => 'Datenbank',
    ];

    protected function configure(): void
    {
        $this
            ->addOption('app', 'a', InputOption::VALUE_REQUIRED, 'Nur eine Anwendung: shop oder essy')
            ->addOption('watch', 'w', InputOption::VALUE_OPTIONAL, 'Alle N Sekunden neu laden', false)
            ->addOption('no-fetch', null, InputOption::VALUE_NONE, 'Kein git fetch im lokalen Repo')
            ->addOption('json', null, InputOption::VALUE_NONE, 'Rohdaten als JSON');
    }

    protected function execute(InputInterface $input, OutputInterface $output): int
    {
        $collector = new Collector($this->environments, $this->runner(new BufferedOutput()));
        $app = $input->getOption('app');
        $watch = $input->getOption('watch');
        $interval = $watch === false ? null : max(5, (int) ($watch ?: 30));

        do {
            $data = $collector->collect($app, !$input->getOption('no-fetch'));
            if ($input->getOption('json')) {
                $plain = [];
                foreach ($data as $name => $block) {
                    $plain[$name] = ['environments' => $block['environments'], 'git' => $block['git']];
                }
                $output->writeln((string) json_encode($plain, JSON_PRETTY_PRINT | JSON_UNESCAPED_SLASHES | JSON_UNESCAPED_UNICODE));
            } else {
                if ($interval !== null) {
                    $output->write("\033[H\033[J");
                }
                $output->writeln(sprintf('<info>ops status</info>  %s%s', date('Y-m-d H:i:s'), $interval ? sprintf('  (alle %d s, Strg+C beendet)', $interval) : ''));
                foreach ($data as $block) {
                    $this->render($output, $block['app']->name, $block['app']->label, $block['environments'], $block['git']);
                }
            }
            if ($interval !== null) {
                sleep($interval);
            }
        } while ($interval !== null);

        return Command::SUCCESS;
    }

    /**
     * @param array<string, array<string, string>> $envs
     * @param array<string, string> $git
     */
    private function render(OutputInterface $output, string $app, string $label, array $envs, array $git): void
    {
        $rows = $app === 'shop' ? self::SHOP_ROWS : self::ESSY_ROWS;
        $table = new Table($output);
        $table->setHeaderTitle($label);
        $table->setHeaders(array_merge([''], array_keys($envs)));
        foreach ($rows as $key => $title) {
            $line = [$title];
            foreach ($envs as $values) {
                $line[] = $this->cell($key, $values);
            }
            $table->addRow($line);
        }
        $output->writeln('');
        $table->render();

        $notes = [];
        if ($app === 'shop' && $git !== []) {
            $notes[] = sprintf('main -> stage: %s offen, stage -> release: %s offen, main -> release: %s offen%s', $git['main_not_on_stage'] ?? '?', $git['stage_not_on_release'] ?? '?', $git['main_not_on_release'] ?? '?', ($git['stage_only'] ?? '0') !== '0' ? sprintf(', %s nur auf stage', $git['stage_only']) : '');
        }
        if ($git !== []) {
            $notes[] = sprintf('lokal: Branch %s, %s Datei(en) geändert, %s Commit(s) nicht gepusht', $git['local_branch'] ?: '(detached)', $git['local_dirty'], $git['local_unpushed']);
        }
        foreach ($notes as $note) {
            $output->writeln('  ' . $note);
        }
    }

    /** @param array<string, string> $v */
    private function cell(string $key, array $v): string
    {
        if (isset($v['error']) && $key !== 'http') {
            return $key === 'php' ? '<error>' . $v['error'] . '</error>' : '';
        }
        switch ($key) {
            case 'http':
                $code = $v['http'] ?? '000';
                $ok = $code === '200' && ($v['title_ok'] ?? 'ja') === 'ja';
                $text = $code === '000' ? 'nicht erreichbar' : $code . (($v['title_ok'] ?? 'ja') === 'nein' ? ', ohne ESSY-Titel' : '');

                return $ok ? '<info>' . $text . '</info>' : '<error>' . $text . '</error>';
            case 'checkout':
                if (!isset($v['checkout_sha'])) {
                    return '';
                }

                return sprintf('%s %s (%s)%s', $v['checkout_branch'] ?? '', $v['checkout_sha'], $v['checkout_date'] ?? '', ($v['checkout_dirty'] ?? '0') !== '0' ? ', ' . $v['checkout_dirty'] . ' geändert' : '');
            case 'deploy':
            case 'sync':
            case 'plugins':
                if (!isset($v[$key . '_at'])) {
                    return '<comment>kein Marker</comment>';
                }
                $extra = [];
                foreach (['sha', 'version', 'customer_data', 'lock'] as $field) {
                    if (isset($v[$key . '_' . $field]) && $v[$key . '_' . $field] !== '') {
                        $extra[] = $field === 'customer_data' ? ($v[$key . '_' . $field] === '1' ? 'mit Kundendaten' : 'ohne Kundendaten') : $v[$key . '_' . $field];
                    }
                }

                return $v[$key . '_at'] . ($extra ? ' (' . implode(', ', $extra) . ')' : '');
            default:
                return $v[$key] ?? '';
        }
    }
}
