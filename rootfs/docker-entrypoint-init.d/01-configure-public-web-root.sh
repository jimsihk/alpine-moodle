#!/bin/sh
#
# Configure NGINX web root for Moodle 5.2 public directory structure
#
set -eu

PUBLIC_ROOT_FILE="${PUBLIC_ROOT_FILE:-/etc/nginx/conf.d/default/server/00-public-web-root.conf}"
NGINX_CONFIG_ROOT="${NGINX_CONFIG_ROOT:-/etc/nginx}"
TARGET_PUBLIC_ROOT="${PUBLIC_WEB_PATH%/}"

rm -f "${PUBLIC_ROOT_FILE}"

REPLACED_EXISTING_ROOT_MARKER="/tmp/configure-public-web-root.$$"
rm -f "${REPLACED_EXISTING_ROOT_MARKER}"

find "${NGINX_CONFIG_ROOT}" -type f -name '*.conf' -exec sh -eu -c '
  conf_file=$1
  target_public_root=$2
  replaced_existing_root_marker=$3

  if grep -Eq "^[[:space:]]*root[[:space:]]+[^;]+;" "${conf_file}"; then
    temp_file="${conf_file}.tmp.$$"
    awk -v target_public_root="${target_public_root}" "
      !root_updated && match(\$0, /^[[:space:]]*root[[:space:]]+[^;]+;/) {
        match(\$0, /^[[:space:]]*/)
        print substr(\$0, 1, RLENGTH) \"root \" target_public_root \";\"
        root_updated = 1
        next
      }
      { print }
    " "${conf_file}" > "${temp_file}"
    mv "${temp_file}" "${conf_file}"
    : > "${replaced_existing_root_marker}"
  fi
' sh {} "${TARGET_PUBLIC_ROOT}" "${REPLACED_EXISTING_ROOT_MARKER}" \;

if [ ! -e "${REPLACED_EXISTING_ROOT_MARKER}" ]; then
  mkdir -p "$(dirname "${PUBLIC_ROOT_FILE}")"
  cat > "${PUBLIC_ROOT_FILE}" <<EOF
root ${TARGET_PUBLIC_ROOT};
EOF
fi

rm -f "${REPLACED_EXISTING_ROOT_MARKER}"
