#!/usr/bin/env python3
import argparse
import pathlib
import re
import sys
from typing import Dict, Iterable, List


ALPINE_REPO_PATTERN = r"alpine_[0-9]+_[0-9]+"
RENOVATE_REPOLOGY_PATTERN = re.compile(
    rf"^# renovate: datasource=repology depName={ALPINE_REPO_PATTERN}/(?P<package_name>[^\s]+) versioning=loose$"
)
PACKAGE_VERSION_PATTERN = re.compile(r'^ARG (?P<arg_name>[A-Z0-9_]+)="[^"]*"$')


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser()
    parser.add_argument("--dockerfile", required=True)
    parser.add_argument("--alpine-repo", required=True)
    parser.add_argument(
        "--package-version",
        action="append",
        default=[],
        help="Version assignment in the form ARG_NAME=version",
    )
    return parser.parse_args()


def extract_package_lines(content: str) -> Dict[str, str]:
    package_lines: Dict[str, str] = {}
    package_line_numbers: Dict[str, int] = {}
    lines = content.splitlines()

    for index, line in enumerate(lines):
        package_match = RENOVATE_REPOLOGY_PATTERN.match(line)
        if package_match is None:
            continue

        if index + 1 >= len(lines):
            continue

        arg_match = PACKAGE_VERSION_PATTERN.match(lines[index + 1])
        if arg_match is None:
            continue

        arg_name = arg_match.group("arg_name")
        if arg_name in package_lines:
            raise ValueError(
                f"Duplicate package version key found in Dockerfile: {arg_name} "
                f"(lines {package_line_numbers[arg_name]} and {index + 2})"
            )

        package_lines[arg_name] = package_match.group("package_name")
        package_line_numbers[arg_name] = index + 2

    if not package_lines:
        raise ValueError("Could not find Alpine package version pins in Dockerfile")

    return package_lines


def build_versions(assignments: List[str], expected_keys: Iterable[str]) -> Dict[str, str]:
    expected = set(expected_keys)
    versions: Dict[str, str] = {}
    for assignment in assignments:
        key, separator, value = assignment.partition("=")
        if separator == "" or not key or not value:
            raise ValueError(f"Invalid package version assignment: {assignment}")
        if key not in expected:
            raise ValueError(f"Unsupported package version key: {key}")
        versions[key] = value

    missing = sorted(expected - set(versions))
    if missing:
        raise ValueError(f"Missing package versions for: {', '.join(missing)}")

    return versions


def replace_or_fail(content: str, pattern: str, replacement: str) -> str:
    updated, replacement_count = re.subn(pattern, replacement, content, count=1, flags=re.MULTILINE)
    if replacement_count != 1:
        raise ValueError(
            f"Could not update pattern exactly once (matched {replacement_count} times): {pattern}"
        )
    return updated


def main() -> int:
    try:
        args = parse_args()
        dockerfile_path = pathlib.Path(args.dockerfile)
        content = dockerfile_path.read_text()
        package_lines = extract_package_lines(content)
        versions = build_versions(args.package_version, package_lines)

        for arg_name, package_name in package_lines.items():
            content = replace_or_fail(
                content,
                rf"^(# renovate: datasource=repology depName=){ALPINE_REPO_PATTERN}/{package_name}( versioning=loose)$",
                rf"\1{args.alpine_repo}/{package_name}\2",
            )
            content = replace_or_fail(
                content,
                rf'^ARG {arg_name}="[^"]*"$',
                f'ARG {arg_name}="={versions[arg_name]}"',
            )

        dockerfile_path.write_text(content)
    except Exception as exc:
        print(f"Error updating Dockerfile: {exc}", file=sys.stderr)
        return 1

    return 0


if __name__ == "__main__":
    raise SystemExit(main())
