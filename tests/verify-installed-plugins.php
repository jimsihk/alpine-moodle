<?php
declare(strict_types=1);

/**
 * Verify that requested Moodle plugins exist on disk and are registered as
 * installed by the running Moodle site's plugin manager.
 */

if ($argc < 2) {
    fwrite(STDERR, "Usage: verify-installed-plugins.php component [component ...]\n");
    exit(2);
}

define('CLI_SCRIPT', true);
require '/var/www/html/config.php';

$manager = core_plugin_manager::instance();
$failed = false;

foreach (array_slice($argv, 1) as $component) {
    if (!preg_match('/^([a-z][a-z0-9]*)_([a-z][a-z0-9_]*)$/', $component, $matches)) {
        fwrite(STDERR, "FAIL: Invalid Moodle plugin component: {$component}\n");
        $failed = true;
        continue;
    }

    [, $type, $name] = $matches;
    $info = $manager->get_plugin_info($type, $name);

    if ($info === null) {
        fwrite(STDERR, "FAIL: {$component} is not discoverable by Moodle's plugin manager\n");
        $failed = true;
        continue;
    }

    if (method_exists($info, 'is_missing') && $info->is_missing()) {
        fwrite(STDERR, "FAIL: {$component} is recorded by Moodle but missing from disk\n");
        $failed = true;
        continue;
    }

    if (!method_exists($info, 'is_installed') || !$info->is_installed()) {
        fwrite(STDERR, "FAIL: {$component} is present but not installed in Moodle's database\n");
        $failed = true;
        continue;
    }

    echo "PASS: {$component} is present and installed in Moodle\n";
}

if ($failed) {
    exit(1);
}

echo "All requested Moodle plugins are installed and discoverable.\n";
