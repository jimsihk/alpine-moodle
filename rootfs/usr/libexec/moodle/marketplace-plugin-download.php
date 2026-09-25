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

function normaliseVersions(array $data): array {
    $versions = $data['versions'] ?? $data['data'] ?? $data;
    if (is_array($versions) && isset($versions['data']) && is_array($versions['data'])) {
        $versions = $versions['data'];
    }
    return is_array($versions) ? $versions : [];
}

try {
    // Marketplace exposes version metadata on the plugin versions page. The download
    // itself is performed through the documented Marketplace API endpoint.
    $versionsUrl = 'https://marketplace.moodle.com/plugins/' . rawurlencode($component) . '/versions?show=all';
    [, $html] = request($versionsUrl, $token);
    $selected = null;

    // Parse each version entry independently. The Marketplace page contains many
    // versions, so looking for a Moodle release within a large window around a build
    // number can accidentally associate a newer, incompatible version with the release.
    $entryPattern = '/Version build number[^0-9]*(\\d{10})(.*?)(?=Version build number|\\z)/is';
    if (!preg_match_all($entryPattern, (string)$html, $entryMatches, PREG_SET_ORDER)) {
        throw new RuntimeException("No Marketplace versions found for {$component}");
    }

    foreach ($entryMatches as $entry) {
        $build = (int)$entry[1];
        $entryHtml = $entry[2];

        if ($build <= 0) {
            continue;
        }
        if ($force) {
            if ($selected === null || $build > $selected['build']) {
                $selected = ['build' => $build];
            }
            continue;
        }

        // Only accept a build when its own Marketplace entry explicitly lists
        // the requested Moodle release.
        if (preg_match('/Moodle\\s+' . preg_quote($moodleRelease, '/') . '\\b/i', $entryHtml)
            && ($selected === null || $build > $selected['build'])) {
            $selected = ['build' => $build];
        }
    }

    if ($selected === null) {
        throw new RuntimeException("No Marketplace version of {$component} is compatible with Moodle {$moodleRelease}");
    }

    $downloadUrl = $apiBase . '/plugins/' . rawurlencode($component)
        . '/versions/' . $selected['build'] . '/download';
    request($downloadUrl, $token, $outputZip);

    if (!is_file($outputZip) || filesize($outputZip) === 0) {
        throw new RuntimeException("Marketplace returned an empty archive for {$component}");
    }

    echo "Selected Marketplace version {$selected['build']} for {$component}\n";
} catch (Throwable $e) {
    @unlink($outputZip);
    fwrite(STDERR, "ERROR: {$e->getMessage()}\n");
    exit(1);
}
