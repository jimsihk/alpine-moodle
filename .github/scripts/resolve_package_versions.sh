#!/usr/bin/env bash
# Resolves Alpine package versions from Repology for each pinned package in the Dockerfile.
# Reads: ALPINE_REPO (env var, e.g. "alpine_3_22")
# Writes: GITHUB_OUTPUT key "package_versions" (multiline EOF block)
set -euo pipefail

REPOLOGY_API_BASE="${REPOLOGY_API_BASE:-https://repology.org/api/v1/project}"
REPOLOGY_FETCH_RETRIES="${REPOLOGY_FETCH_RETRIES:-4}"
REPOLOGY_FETCH_RETRY_DELAY_SECONDS="${REPOLOGY_FETCH_RETRY_DELAY_SECONDS:-2}"
REPOLOGY_CONNECT_TIMEOUT_SECONDS="${REPOLOGY_CONNECT_TIMEOUT_SECONDS:-15}"
REPOLOGY_MAX_TIME_SECONDS="${REPOLOGY_MAX_TIME_SECONDS:-45}"

fetch_repology_data() {
  local package_name="$1"
  local response_file="$2"
  local attempt=1

  while [ "${attempt}" -le "${REPOLOGY_FETCH_RETRIES}" ]; do
    if curl -fsSL \
      --connect-timeout "${REPOLOGY_CONNECT_TIMEOUT_SECONDS}" \
      --max-time "${REPOLOGY_MAX_TIME_SECONDS}" \
      "${REPOLOGY_API_BASE}/${package_name}" \
      -o "${response_file}"; then
      return 0
    fi

    if [ "${attempt}" -lt "${REPOLOGY_FETCH_RETRIES}" ]; then
      echo "::warning::Repology fetch failed for ${package_name} (attempt ${attempt}/${REPOLOGY_FETCH_RETRIES}); retrying in ${REPOLOGY_FETCH_RETRY_DELAY_SECONDS}s" >&2
      sleep "${REPOLOGY_FETCH_RETRY_DELAY_SECONDS}"
    fi

    attempt="$((attempt + 1))"
  done

  echo "::error::Failed to fetch Repology data for ${package_name} after ${REPOLOGY_FETCH_RETRIES} attempts" >&2
  return 1
}

resolve_package_version() {
  local package_name="$1"
  local response_file
  local resolved_version
  response_file="$(mktemp)"

  if ! fetch_repology_data "${package_name}" "${response_file}"; then
    return 1
  fi

  if ! jq -e . "${response_file}" >/dev/null; then
    echo "::error::Repology returned invalid JSON for ${package_name}" >&2
    return 1
  fi

  if ! jq -e 'type == "array" or type == "object"' "${response_file}" >/dev/null; then
    echo "::error::Repology returned unsupported JSON structure for ${package_name}" >&2
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
