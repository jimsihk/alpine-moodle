<?php
declare(strict_types=1);

if ($argc !== 2) {
    fwrite(STDERR, "Usage: validate-plugin-archive.php ARCHIVE.zip\n");
    exit(2);
}

$archivePath = $argv[1];
if (!is_file($archivePath) || !class_exists(ZipArchive::class)) {
    fwrite(STDERR, "ERROR: ZIP archive is missing or PHP ZipArchive is unavailable\n");
    exit(1);
}

$zip = new ZipArchive();
$result = $zip->open($archivePath);
if ($result !== true) {
    fwrite(STDERR, "ERROR: Unable to open plugin ZIP archive\n");
    exit(1);
}

try {
    $root = null;
    $seen = [];
    $hasVersionFile = false;

    for ($index = 0; $index < $zip->numFiles; $index++) {
        $name = $zip->getNameIndex($index);
        if (!is_string($name) || $name === ''
            || str_contains($name, "\\")
            || preg_match('/[\x00-\x1F\x7F]/', $name)
            || str_starts_with($name, '/')
            || preg_match('/^[A-Za-z]:/', $name)) {
            throw new RuntimeException('ZIP contains an unsafe entry name');
        }

        $isDirectory = str_ends_with($name, '/');
        $normalized = $isDirectory ? substr($name, 0, -1) : $name;
        $segments = explode('/', $normalized);
        if ($normalized === '' || in_array('', $segments, true)
            || in_array('.', $segments, true) || in_array('..', $segments, true)) {
            throw new RuntimeException('ZIP contains an unsafe path component');
        }

        if (isset($seen[$normalized])) {
            throw new RuntimeException('ZIP contains duplicate entry paths');
        }
        $seen[$normalized] = true;

        if ($root === null) {
            $root = $segments[0];
        } elseif ($segments[0] !== $root) {
            throw new RuntimeException('ZIP must contain exactly one top-level plugin directory');
        }

        if (count($segments) === 1 && !$isDirectory) {
            throw new RuntimeException('ZIP contains a file outside the plugin directory');
        }
        if ($normalized === $root . '/version.php' && !$isDirectory) {
            $hasVersionFile = true;
        }

        if ($zip->getExternalAttributesIndex($index, $operatingSystem, $attributes)
            && $operatingSystem === ZipArchive::OPSYS_UNIX) {
            $fileType = ($attributes >> 16) & 0170000;
            if (!in_array($fileType, [0, 0100000, 0040000], true)) {
                throw new RuntimeException('ZIP contains a symbolic link or special file');
            }
            if ($isDirectory && $fileType === 0100000) {
                throw new RuntimeException('ZIP directory entry has regular-file attributes');
            }
            if (!$isDirectory && $fileType === 0040000) {
                throw new RuntimeException('ZIP file entry has directory attributes');
            }
        }
    }

    if ($root === null || !$hasVersionFile) {
        throw new RuntimeException('ZIP must contain one plugin directory with a top-level version.php');
    }
} catch (Throwable $error) {
    fwrite(STDERR, 'ERROR: ' . $error->getMessage() . "\n");
    $zip->close();
    exit(1);
}

$zip->close();
exit(0);
