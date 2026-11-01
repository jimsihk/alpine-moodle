#!/usr/bin/env sh
set -e

MAX_WAIT=600  # 10 minutes

# Check that the database is available
echo "Waiting for moodle to be ready"
START_TIME=$(date +%s)
while ! nc -w 1 app 8080; do
    echo -n '.'
    sleep 1
    if [ $(( $(date +%s) - START_TIME )) -ge $MAX_WAIT ]; then
        echo ""
        echo "Error: Timed out after ${MAX_WAIT}s waiting for moodle to start"
        exit 1
    fi
done
echo "moodle is ready"
# Give Moodle a moment to finish its initial HTTP startup.
sleep 3

wget -q -O - http://app:8080 | grep '>Dockerized_Moodle<'

# Exercise authenticated Moodle pages and installed plugins.
python3 /tmp/run_tests.py
