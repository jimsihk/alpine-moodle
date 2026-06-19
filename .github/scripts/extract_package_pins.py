#!/usr/bin/env python3
"""Print ARG_NAME=package_name pairs for every Renovate-pinned Alpine package in the Dockerfile."""
import pathlib
import re

dockerfile = pathlib.Path("Dockerfile").read_text().splitlines()
comment_pattern = re.compile(
    r"^# renovate: datasource=repology depName=alpine_[0-9]+_[0-9]+/(?P<package_name>[^\s]+) versioning=loose$"
)
arg_pattern = re.compile(r'^ARG (?P<arg_name>[A-Z0-9_]+)="[^"]*"$')

for index, line in enumerate(dockerfile):
    comment_match = comment_pattern.match(line)
    if comment_match is None or index + 1 >= len(dockerfile):
        continue

    arg_match = arg_pattern.match(dockerfile[index + 1])
    if arg_match is None:
        continue

    print(f"{arg_match.group('arg_name')}={comment_match.group('package_name')}")
