#!/bin/sh
#
# Configure NGINX web root for Moodle 5.2 public directory structure
#
set -eu

PUBLIC_ROOT_FILE='/etc/nginx/conf.d/default/server/00-public-web-root.conf'

mkdir -p "$(dirname "${PUBLIC_ROOT_FILE}")"

cat > "${PUBLIC_ROOT_FILE}" <<EOF
    root ${PUBLIC_WEB_PATH%/};
EOF
