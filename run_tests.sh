#!/usr/bin/env sh
set -e

MAX_WAIT=600  # 10 minutes
SITE_NAME='Dockerized_Moodle'

# Check that the database is available
echo "Waiting for moodle to be ready"
START_TIME=$(date +%s)
while ! nc -w 1 app 8080; do
    # Show some progress
    echo -n '.';
    sleep 1;
    if [ $(( $(date +%s) - START_TIME )) -ge $MAX_WAIT ]; then
        echo ""
        echo "Error: Timed out after ${MAX_WAIT}s waiting for moodle to start"
        exit 1
    fi
done
echo "moodle is ready"
# Give it another 3 seconds.
sleep 3;

echo "Waiting for Moodle page content"
START_TIME=$(date +%s)
while true; do
    if wget -q -O - http://app:8080 | grep -q "${SITE_NAME}"; then
        echo "Moodle page content is ready"
        break
    fi
    echo -n '.';
    sleep 1;
    if [ $(( $(date +%s) - START_TIME )) -ge $MAX_WAIT ]; then
        echo ""
        echo "Error: Timed out after ${MAX_WAIT}s waiting for Moodle page content"
        exit 1
    fi
done
