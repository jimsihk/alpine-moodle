#!/usr/bin/env bash
# Resolves Alpine package versions from Repology for each pinned package in the Dockerfile.
# Reads: ALPINE_REPO (env var, e.g. "alpine_3_22")
# Writes: GITHUB_OUTPUT key "package_versions" (multiline EOF block)
set -euo pipefail

resolve_package_version() {
  local package_name="$1"
  local response_file
  local resolved_version
  response_file="$(mktemp)"

  if ! curl -fsSL "https://repology.org/api/v1/project/${package_name}" -o "${response_file}"; then
    echo "::error::Failed to fetch Repology data for ${package_name}" >&2
    return 1
  fi

  if ! jq -e . "${response_file}" >/dev/null; then
    echo "::error::Repology returned invalid JSON for ${package_name}" >&2
    return 1
  fi

  resolved_version="$(
    jq -r --arg repo "${ALPINE_REPO}" '
      if type == "array" then
        map(select(.repo == $repo))[0].version // empty
      else
        .[$repo].version // empty
      end
    ' "${response_file}"
  )"

  if [ -z "${resolved_version}" ] || [ "${resolved_version}" = "null" ]; then
    echo "::error::Could not resolve ${package_name} for ${ALPINE_REPO}" >&2
    return 1
  fi

  printf '%s\n' "${resolved_version}"
}

package_assignments_file="$(mktemp)"

while IFS='=' read -r arg_name package_name; do
  [ -n "${arg_name}" ] || continue
  resolved_version="$(resolve_package_version "${package_name}")" || exit 1
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
