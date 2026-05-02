#!/usr/bin/env python3
import argparse
import pathlib
import re
import sys
from typing import Dict, List


PACKAGE_LINES = {
    "DCRON_VERSION": "dcron",
    "LIBCAP_VERSION": "libcap",
    "GIT_VERSION": "git",
    "BASH_VERSION": "bash",
}


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


def build_versions(assignments: List[str]) -> Dict[str, str]:
    versions: Dict[str, str] = {}
    for assignment in assignments:
        key, separator, value = assignment.partition("=")
        if separator == "" or not key or not value:
            raise ValueError(f"Invalid package version assignment: {assignment}")
        if key not in PACKAGE_LINES:
            raise ValueError(f"Unsupported package version key: {key}")
        versions[key] = value

    missing = sorted(set(PACKAGE_LINES) - set(versions))
    if missing:
        raise ValueError(f"Missing package versions for: {', '.join(missing)}")

    return versions


def replace_or_fail(content: str, pattern: str, replacement: str) -> str:
    updated, count = re.subn(pattern, replacement, content, count=1, flags=re.MULTILINE)
    if count != 1:
        raise ValueError(f"Could not update pattern: {pattern}")
    return updated


def main() -> int:
    try:
        args = parse_args()
        versions = build_versions(args.package_version)
        dockerfile_path = pathlib.Path(args.dockerfile)
        content = dockerfile_path.read_text()

        for arg_name, package_name in PACKAGE_LINES.items():
            content = replace_or_fail(
                content,
                rf"^(# renovate: datasource=repology depName=)alpine_[0-9]+_[0-9]+/{package_name}( versioning=loose)$",
                rf"\1{args.alpine_repo}/{package_name}\2",
            )
            content = replace_or_fail(
                content,
                rf'^ARG {arg_name}="=[^"]*"$',
                f'ARG {arg_name}="={versions[arg_name]}"',
            )

        dockerfile_path.write_text(content)
    except Exception as exc:
        print(exc, file=sys.stderr)
        return 1

    return 0


if __name__ == "__main__":
    raise SystemExit(main())
