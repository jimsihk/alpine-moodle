#!/usr/bin/env bash
# Resolves Alpine package versions from Repology for each pinned package in the Dockerfile.
# Reads: ALPINE_REPO (env var, e.g. "alpine_3_22")
# Writes: GITHUB_OUTPUT key "package_versions" (multiline EOF block)
set -euo pipefail

REPOLOGY_API_BASE="${REPOLOGY_API_BASE:-https://repology.org/api/v1/project}"
# Maximum number of fetch attempts including the initial call.
REPOLOGY_MAX_ATTEMPTS="${REPOLOGY_MAX_ATTEMPTS:-4}"
REPOLOGY_INITIAL_RETRY_DELAY_SECONDS="${REPOLOGY_INITIAL_RETRY_DELAY_SECONDS:-2}"
REPOLOGY_FETCH_MAX_RETRY_DELAY_SECONDS="${REPOLOGY_FETCH_MAX_RETRY_DELAY_SECONDS:-30}"
REPOLOGY_CONNECT_TIMEOUT_SECONDS="${REPOLOGY_CONNECT_TIMEOUT_SECONDS:-15}"
REPOLOGY_MAX_TIME_SECONDS="${REPOLOGY_MAX_TIME_SECONDS:-45}"

fetch_repology_data() {
  local package_name="$1"
  local response_file="$2"
  local attempt=1
  local retry_delay="${REPOLOGY_INITIAL_RETRY_DELAY_SECONDS}"

  while [ "${attempt}" -le "${REPOLOGY_MAX_ATTEMPTS}" ]; do
    if curl -fsSL \
      --connect-timeout "${REPOLOGY_CONNECT_TIMEOUT_SECONDS}" \
      --max-time "${REPOLOGY_MAX_TIME_SECONDS}" \
      "${REPOLOGY_API_BASE}/${package_name}" \
      -o "${response_file}"; then
      return 0
    fi

    if [ "${attempt}" -lt "${REPOLOGY_MAX_ATTEMPTS}" ]; then
      echo "::warning::Repology fetch failed for ${package_name} (attempt ${attempt}/${REPOLOGY_MAX_ATTEMPTS}); retrying in ${retry_delay}s" >&2
      sleep "${retry_delay}"
      retry_delay="$((retry_delay * 2))"
      if [ "${retry_delay}" -gt "${REPOLOGY_FETCH_MAX_RETRY_DELAY_SECONDS}" ]; then
        retry_delay="${REPOLOGY_FETCH_MAX_RETRY_DELAY_SECONDS}"
      fi
    fi

    attempt="$((attempt + 1))"
  done

  echo "::error::Failed to fetch Repology data for ${package_name} after ${REPOLOGY_MAX_ATTEMPTS} attempts" >&2
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

  # Repology API responses can be either an array of package rows or an object keyed by repo.
  # Validate that the requested Alpine repo has a non-empty version in either structure.
  if ! jq -e --arg repo "${ALPINE_REPO}" '
    (type == "array" and any(.[]; .repo? == $repo and (.version // "") != "")) or
    (type == "object" and ((.[$repo].version // "") != ""))
  ' "${response_file}" >/dev/null; then
    echo "::error::Repology payload does not include a usable ${ALPINE_REPO} version for ${package_name}" >&2
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
