#!/usr/bin/env bash
# Resolves Alpine package versions directly from the Alpine APK repository.
# Reads: ALPINE_SERIES (env var, e.g. "3.24")
# Writes: GITHUB_OUTPUT key "package_versions" (multiline EOF block)
set -euo pipefail

ALPINE_SERIES="${ALPINE_SERIES:?ALPINE_SERIES must be set}"

if ! [[ "${ALPINE_SERIES}" =~ ^[0-9]+\.[0-9]+$ ]]; then
  echo "::error::ALPINE_SERIES must be an Alpine major/minor version (got '${ALPINE_SERIES}')" >&2
  exit 1
fi

package_assignments_file="$(mktemp)"
trap 'rm -f "${package_assignments_file}"' EXIT

resolve_package_version() {
  local package_name="$1"
  local result

  result="$(docker run --rm "alpine:${ALPINE_SERIES}" sh -c '
    set -e
    apk update -q
    apk search -e "$1" | head -n 1
  ' sh "${package_name}")"

  if [ -z "${result}" ]; then
    echo "::error::Could not resolve ${package_name} for Alpine ${ALPINE_SERIES}" >&2
    return 1
  fi

  printf '%s\n' "${result}" | sed "s/^${package_name}-//"
}

while IFS='=' read -r arg_name package_name; do
  [ -n "${arg_name}" ] || continue
  resolved_version="$(resolve_package_version "${package_name}")" || exit 1
  if ! printf '%s\n' "${resolved_version}" | grep -qE '^[0-9]'; then
    echo "::error::Invalid APK version for ${package_name}: ${resolved_version}" >&2
    exit 1
  fi
  printf '%s=%s\n' "${arg_name}" "${resolved_version}" >> "${package_assignments_file}"
done < <(python3 .github/scripts/extract_package_pins.py)

if ! [ -s "${package_assignments_file}" ]; then
  echo "::error::Could not determine Alpine package pins from Dockerfile"
  exit 1
fi

{
  echo "package_versions<<EOF"
  cat "${package_assignments_file}"
  echo "EOF"
} >> "${GITHUB_OUTPUT}"
