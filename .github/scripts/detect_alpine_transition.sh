#!/usr/bin/env bash
# Detects whether a Renovate PR transitions Alpine to a new major/minor series.
# Reads: BASE_SHA, HEAD_SHA, PR_AUTHOR, PR_HEAD_REF (env vars)
# Writes: GITHUB_OUTPUT keys (skip_reason or ready/old_tag/new_tag/old_series/new_series/new_repo)
set -euo pipefail

if [ "${PR_AUTHOR}" != 'renovate[bot]' ]; then
  echo "skip_reason=PR author is not Renovate" >> "${GITHUB_OUTPUT}"
  exit 0
fi

case "${PR_HEAD_REF}" in
  renovate/*) ;;
  *)
    echo "skip_reason=PR branch is not a Renovate branch" >> "${GITHUB_OUTPUT}"
    exit 0
    ;;
esac

base_file="$(mktemp)"
head_file="$(mktemp)"
git show "${BASE_SHA}:Dockerfile" > "${base_file}"
git show "${HEAD_SHA}:Dockerfile" > "${head_file}"

extract_image_ref() {
  local file="$1"
  local arch
  local from_image
  arch="$(sed -nE 's/^ARG ARCH=//p' "${file}" | head -n 1)"
  from_image="$(sed -nE 's/^FROM (.*)$/\1/p' "${file}" | head -n 1)"

  if [ -z "${arch}" ] || [ -z "${from_image}" ]; then
    echo "::error::Could not determine image reference from ${file}"
    exit 1
  fi

  printf '%s\n' "${from_image/\$\{ARCH\}/${arch}}"
}

extract_base_tag() {
  local file="$1"
  sed -nE 's#^FROM .*jimsihk/alpine-php-nginx:([^[:space:]]+)$#\1#p' "${file}" | head -n 1
}

old_tag="$(extract_base_tag "${base_file}")"
new_tag="$(extract_base_tag "${head_file}")"

if [ -z "${old_tag}" ] || [ -z "${new_tag}" ]; then
  echo "::error::Could not determine base image tags from Dockerfile"
  exit 1
fi

if [ "${old_tag}" = "${new_tag}" ]; then
  echo "skip_reason=Base image tag did not change" >> "${GITHUB_OUTPUT}"
  exit 0
fi

old_image="$(extract_image_ref "${base_file}")"
new_image="$(extract_image_ref "${head_file}")"

if ! old_release="$(docker run --rm --entrypoint cat "${old_image}" /etc/alpine-release)"; then
  echo "::error::Failed to read Alpine release from ${old_image}"
  exit 1
fi

if ! new_release="$(docker run --rm --entrypoint cat "${new_image}" /etc/alpine-release)"; then
  echo "::error::Failed to read Alpine release from ${new_image}"
  exit 1
fi

old_series="$(printf '%s' "${old_release}" | cut -d '.' -f 1,2)"
new_series="$(printf '%s' "${new_release}" | cut -d '.' -f 1,2)"

if [ "${old_series}" = "${new_series}" ]; then
  echo "skip_reason=Alpine major/minor version did not change" >> "${GITHUB_OUTPUT}"
  exit 0
fi

echo "ready=true" >> "${GITHUB_OUTPUT}"
echo "old_tag=${old_tag}" >> "${GITHUB_OUTPUT}"
echo "new_tag=${new_tag}" >> "${GITHUB_OUTPUT}"
echo "old_series=${old_series}" >> "${GITHUB_OUTPUT}"
echo "new_series=${new_series}" >> "${GITHUB_OUTPUT}"
echo "new_repo=alpine_$(printf '%s' "${new_series}" | tr '.' '_')" >> "${GITHUB_OUTPUT}"
