#!/usr/bin/env sh
set -e

MAX_WAIT=600  # 10 minutes

# Check that the database is available
echo "Waiting for moodle to be ready"
START_TIME=$(date +%s)
while ! nc -w 1 app 8080; do
    # Show some progress
    echo -n '.';
    sleep 1
    if [ $(( $(date +%s) - START_TIME )) -ge $MAX_WAIT ]; then
        echo ""
        echo "Error: Timed out after ${MAX_WAIT}s waiting for moodle to start"
        exit 1
    fi
done
echo "moodle is ready"
# Give it another 3 seconds.
sleep 3

wget -q -O - http://app:8080 | grep '>Dockerized_Moodle<'

echo "Logging in to Moodle to check installed Marketplace plugins"
apk add --no-cache curl >/dev/null

COOKIE_JAR=$(mktemp)
LOGIN_PAGE=$(mktemp)
trap 'rm -f "$COOKIE_JAR" "$LOGIN_PAGE" /tmp/moodle-login-result.html' EXIT

curl -fsS -c "$COOKIE_JAR" -b "$COOKIE_JAR"     http://app:8080/login/index.php     -o "$LOGIN_PAGE"

LOGIN_TOKEN=$(grep -oE 'name="logintoken"[^>]*value="[^"]+"' "$LOGIN_PAGE"     | sed -E 's/.*value="([^"]+)".*/\1/'     | head -n 1)

if [ -z "$LOGIN_TOKEN" ]; then
    echo "ERROR: Could not find Moodle login token"
    exit 1
fi

curl -fsS -L     -c "$COOKIE_JAR"     -b "$COOKIE_JAR"     -e http://app:8080/login/index.php     --data-urlencode "username=moodleuser"     --data-urlencode "password=PLEASE_CHANGEME"     --data-urlencode "logintoken=$LOGIN_TOKEN"     http://app:8080/login/index.php     -o /tmp/moodle-login-result.html

echo "Checking Marketplace plugin installations"
curl -fsS -b "$COOKIE_JAR"     http://app:8080/admin/plugins.php     | grep -q 'Moove'

echo "Marketplace plugin installation test passed"
