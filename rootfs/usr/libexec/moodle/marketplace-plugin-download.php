<?php
declare(strict_types=1);

if ($argc !== 6) {
    fwrite(STDERR, "Usage: marketplace-plugin-download.php COMPONENT MOODLE_RELEASE MIN_MATURITY FORCE OUTPUT_ZIP\n");
    exit(2);
}

[, $component, $moodleRelease, $minimumMaturity, $force, $outputZip] = $argv;
$minimumMaturity = (int)$minimumMaturity;
$force = $force === 'true';
$apiBase = rtrim(getenv('MOODLE_MARKETPLACE_API') ?: 'https://marketplace.moodle.com/api', '/');
$tokenFile = getenv('MOODLE_MARKETPLACE_TOKEN_FILE') ?: '/run/secrets/MOODLE_MARKETPLACE_TOKEN';
$token = '';
if (is_readable($tokenFile)) {
    $token = trim((string)file_get_contents($tokenFile));
}
if (getenv('MOODLE_MARKETPLACE_TOKEN_REQUIRED') === 'true' && $token === '') {
    throw new RuntimeException('MOODLE_MARKETPLACE_TOKEN is required for this test/build');
}

function request(string $url, string $token, ?string $output = null): array {
    $curl = curl_init($url);
    if ($curl === false) {
        throw new RuntimeException('Unable to initialise cURL');
    }

    $headers = [
        'Accept: application/json',
        'User-Agent: alpine-moodle/MarketplacePluginInstaller',
    ];
    if ($token !== '') {
        $headers[] = 'Authorization: Bearer ' . $token;
    }

    $options = [
        CURLOPT_RETURNTRANSFER => $output === null,
        CURLOPT_FOLLOWLOCATION => true,
        CURLOPT_MAXREDIRS => 5,
        CURLOPT_HTTPHEADER => $headers,
        CURLOPT_SSL_VERIFYHOST => 2,
        CURLOPT_SSL_VERIFYPEER => true,
        CURLOPT_FAILONERROR => false,
    ];

    if ($output !== null) {
        $fp = fopen($output, 'wb');
        if ($fp === false) {
            throw new RuntimeException('Unable to open output file');
        }
        $options[CURLOPT_FILE] = $fp;
    }

    curl_setopt_array($curl, $options);
    $body = curl_exec($curl);
    $errno = curl_errno($curl);
    $error = curl_error($curl);
    $status = (int)curl_getinfo($curl, CURLINFO_RESPONSE_CODE);
    curl_close($curl);
    if (isset($fp) && is_resource($fp)) {
        fclose($fp);
    }

    if ($errno !== 0) {
        throw new RuntimeException("Marketplace request failed: {$error}");
    }
    if ($status < 200 || $status >= 300) {
        if ($output !== null) {
            @unlink($output);
        }
        throw new RuntimeException("Marketplace API returned HTTP {$status}");
    }

    return [$status, $body];
}

function maturityScore(mixed $value): int {
    if (is_numeric($value)) {
        return (int)$value;
    }
    return match (strtoupper((string)$value)) {
        'STABLE' => 200,
        'RC' => 150,
        'BETA' => 100,
        'ALPHA' => 50,
        default => 0,
    };
}

function validatePluginVersion(
    string $zip,
    string $component,
    string $moodleRelease,
    int|float $coreVersion
): bool {
    $tempDir = sys_get_temp_dir() . '/moodle-plugin-' . bin2hex(random_bytes(8));
    if (!mkdir($tempDir, 0700, true)) {
        throw new RuntimeException('Unable to create plugin validation directory');
    }

    try {
        $command = sprintf(
            'unzip -q %s -d %s',
            escapeshellarg($zip),
            escapeshellarg($tempDir)
        );
        exec($command, $unusedOutput, $status);
        if ($status !== 0) {
            throw new RuntimeException('Unable to extract Marketplace plugin archive for validation');
        }

        $versionFiles = glob($tempDir . '/*/version.php');
        if ($versionFiles === false || count($versionFiles) !== 1) {
            throw new RuntimeException("{$component} archive does not contain exactly one top-level version.php");
        }

        $versionFile = $versionFiles[0];
        if (!defined('MOODLE_INTERNAL')) {
            define('MOODLE_INTERNAL', true);
            define('MATURITY_ALPHA', 50);
            define('MATURITY_BETA', 100);
            define('MATURITY_RC', 150);
            define('MATURITY_STABLE', 200);
        }

        $plugin = null;
        require $versionFile;

        if (!is_object($plugin) || ($plugin->component ?? null) !== $component) {
            throw new RuntimeException("{$component} version.php declares an unexpected component");
        }
        if (!isset($plugin->version) || !is_numeric($plugin->version)) {
            throw new RuntimeException("{$component} version.php does not declare a valid plugin version");
        }

        if (!preg_match('/^(\\d+)\\.(\\d+)$/', $moodleRelease, $releaseParts)) {
            throw new RuntimeException("Invalid Moodle release: {$moodleRelease}");
        }
        $branch = (int)$releaseParts[1] * 100 + (int)$releaseParts[2];
        if (isset($plugin->requires) && is_numeric($plugin->requires)
            && (float)$plugin->requires > (float)$coreVersion) {
            echo "Rejected Marketplace build {$plugin->version} for {$component}: requires Moodle {$plugin->requires}, core is {$coreVersion}\n";
            return false;
        }

        if (isset($plugin->supported)) {
            if (!is_array($plugin->supported) || count($plugin->supported) !== 2
                || !is_numeric($plugin->supported[0]) || !is_numeric($plugin->supported[1])) {
                throw new RuntimeException("{$component} version.php has invalid supported metadata");
            }
            if ($branch < (int)$plugin->supported[0] || $branch > (int)$plugin->supported[1]) {
                echo "Rejected Marketplace build {$plugin->version} for {$component}: Moodle branch {$branch} is outside supported range\n";
                return false;
            }
        }

        if (isset($plugin->incompatible) && $plugin->incompatible !== null
            && is_numeric($plugin->incompatible)
            && $branch >= (int)$plugin->incompatible) {
            echo "Rejected Marketplace build {$plugin->version} for {$component}: Moodle branch {$branch} is incompatible\n";
            return false;
        }

        return true;
    } finally {
        exec(sprintf('rm -rf %s', escapeshellarg($tempDir)));
    }
}

try {
    // The Marketplace versions page is used for release discovery. Compatibility is
    // then verified from the candidate ZIP's version.php, using the same metadata
    // Moodle core uses during plugin installation.
    $versionsUrl = 'https://marketplace.moodle.com/plugins/' . rawurlencode($component) . '/versions?show=all';
    [, $html] = request($versionsUrl, $token);

    $text = html_entity_decode(strip_tags((string)$html), ENT_QUOTES | ENT_HTML5, 'UTF-8');
    $text = preg_replace('/[[:space:]]+/', ' ', $text) ?? $text;

    $entryPattern = '/Maturity:\s*([^\s]+)\s+Supported Moodle versions:\s*(.*?)\s+Repository URL.*?Version build number:\s*(\d{10})/i';
    if (!preg_match_all($entryPattern, $text, $entryMatches, PREG_SET_ORDER)) {
        throw new RuntimeException("No Marketplace versions found for {$component}");
    }

    $candidates = [];
    foreach ($entryMatches as $entry) {
        $maturity = maturityScore($entry[1]);
        $supportedMoodle = trim($entry[2]);
        $build = (int)$entry[3];
        if ($build <= 0) {
            continue;
        }

        if (($force || preg_match(
            '/(?:^|[^0-9])' . preg_quote($moodleRelease, '/') . '(?:$|[^0-9])/i',
            $supportedMoodle
        )) && ($force || $maturity >= $minimumMaturity)) {
            $candidates[$build] = $build;
        }
    }

    if ($force) {
        // Forced installs deliberately bypass Marketplace compatibility filtering,
        // but still validate the archive structure before installing it.
        foreach ($entryMatches as $entry) {
            $build = (int)$entry[3];
            if ($build > 0) {
                $candidates[$build] = $build;
            }
        }
    }

    if ($candidates === []) {
        throw new RuntimeException("No Marketplace version of {$component} is compatible with Moodle {$moodleRelease}");
    }

    rsort($candidates, SORT_NUMERIC);

    $candidateDir = dirname($outputZip);
    if (!is_dir($candidateDir) && !mkdir($candidateDir, 0700, true) && !is_dir($candidateDir)) {
        throw new RuntimeException('Unable to create Marketplace download directory');
    }

    $coreVersion = getenv('MOODLE_CORE_VERSION');
    if ($coreVersion === false || !is_numeric($coreVersion)) {
        throw new RuntimeException('MOODLE_CORE_VERSION is required to validate Marketplace plugin compatibility');
    }

    foreach ($candidates as $build) {
        $candidateZip = $candidateDir . '/candidate-' . $build . '.zip';
        $downloadUrl = $apiBase . '/plugins/' . rawurlencode($component)
            . '/versions/' . $build . '/download';

        echo "Checking Marketplace version {$build} for {$component}\n";
        request($downloadUrl, $token, $candidateZip);

        try {
            if (!is_file($candidateZip) || filesize($candidateZip) === 0) {
                throw new RuntimeException("Marketplace returned an empty archive for {$component}");
            }

            if (validatePluginVersion($candidateZip, $component, $moodleRelease, $coreVersion)) {
                if ($candidateZip !== $outputZip) {
                    rename($candidateZip, $outputZip);
                }
                echo "Selected Marketplace version {$build} for {$component}\n";
                exit(0);
            }
        } finally {
            if (is_file($candidateZip)) {
                @unlink($candidateZip);
            }
        }
    }

    throw new RuntimeException("No Marketplace plugin archive passed Moodle compatibility validation for {$component} on Moodle {$moodleRelease}");
} catch (Throwable $e) {
    @unlink($outputZip);
    fwrite(STDERR, "ERROR: {$e->getMessage()}\n");
    exit(1);
}
