#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
PROJECT="replica-failover-${GITHUB_RUN_ID:-local}-${GITHUB_RUN_ATTEMPT:-1}"
OVERRIDE_FILE="$(mktemp)"
COMPOSE=(docker compose --project-name "${PROJECT}" --file "${ROOT_DIR}/docker-compose.test.yml" --file "${OVERRIDE_FILE}")

fail() {
  echo "FAIL: $*" >&2
  "${COMPOSE[@]}" logs app postgres replica 2>/dev/null || true
  exit 1
}

cleanup() {
  "${COMPOSE[@]}" down --volumes --remove-orphans >/dev/null 2>&1 || true
  rm -f "${OVERRIDE_FILE}"
}
trap cleanup EXIT

cat > "${OVERRIDE_FILE}" <<'YAML'
services:
  app:
    environment:
      DB_HOST: postgres
      DB_PORT: "5432"
      DB_HOST_REPLICA: replica
      DB_PORT_REPLICA: "5432"
      DB_USER_REPLICA: moodledbuser
      DB_PASS_REPLICA: moodledbpass
      DB_DBPERSIST: "false"
    depends_on: []

  replica:
    image: postgres:17
    environment:
      POSTGRES_PASSWORD: moodledbpass
      POSTGRES_USER: moodledbuser
      POSTGRES_DB: moodle
    healthcheck:
      test: ["CMD-SHELL", "pg_isready -U moodledbuser -d moodle"]
      interval: 2s
      timeout: 2s
      retries: 30
YAML

"${COMPOSE[@]}" config --quiet

export TEST_IMAGE_NAME="${TEST_IMAGE_NAME:-jimsihk/alpine-moodle:replica-failover-test}"

echo "Building Moodle container image..."
"${COMPOSE[@]}" build app

echo "Starting the primary database and Redis..."
"${COMPOSE[@]}" up -d postgres redis
for attempt in $(seq 1 60); do
  if "${COMPOSE[@]}" exec -T postgres pg_isready -U moodledbuser -d moodle >/dev/null 2>&1; then
    break
  fi
  if [[ "${attempt}" -eq 60 ]]; then
    fail "primary PostgreSQL did not become ready"
  fi
  sleep 2
done

echo "Starting Moodle while the read replica is absent..."
"${COMPOSE[@]}" up -d --no-deps app

echo "Waiting for the installed Moodle homepage to become available..."
for attempt in $(seq 1 180); do
  if "${COMPOSE[@]}" exec -T app sh -c 'wget -q -O - http://127.0.0.1:8080/' 2>/dev/null \
    | grep -F '>Dockerized_Moodle<' >/dev/null; then
    break
  fi
  if [[ "${attempt}" -eq 180 ]]; then
    fail "Moodle did not finish installation while the replica was absent"
  fi
  sleep 5
done

"${COMPOSE[@]}" logs app | grep -F 'WARNING: Read replica replica:5432 is not reachable; continuing startup with the primary database' >/dev/null \
  || fail "startup did not log the expected warning for the unavailable replica"

primary_id="$("${COMPOSE[@]}" ps -q postgres)"
primary_ip="$(docker inspect --format '{{range .NetworkSettings.Networks}}{{.IPAddress}}{{end}}' "${primary_id}")"
[[ -n "${primary_ip}" ]] || fail "could not determine the primary database container IP"

read_server_ip() {
  "${COMPOSE[@]}" exec -T app php -r '
    define("CLI_SCRIPT", true);
    require "/var/www/html/config.php";
    $record = $DB->get_record_sql("SELECT inet_server_addr() AS server_addr FROM {course} LIMIT 1");
    if (!$record || empty($record->server_addr)) {
        fwrite(STDERR, "Database query did not return a server address\n");
        exit(1);
    }
    echo $record->server_addr, PHP_EOL;
  ' | tr -d '\r'
}

assert_read_server() {
  local expected="$1" description="$2" actual
  actual="$(read_server_ip)" || fail "${description}: Moodle database read query failed"
  if [[ "${actual}" != "${expected}" ]]; then
    fail "${description}: expected database server ${expected}, got ${actual}"
  fi
  echo "PASS: ${description} (${actual})"
}

# Moodle's default replica consistency window is one second. Allow the
# installation writes to settle before checking that a normal table read uses
# the replica-aware DML path.
sleep 2
assert_read_server "${primary_ip}" "Moodle starts and falls back to the primary while the replica is unavailable"

echo "Starting the read replica and copying the initialized Moodle database..."
"${COMPOSE[@]}" up -d replica
for attempt in $(seq 1 60); do
  if "${COMPOSE[@]}" exec -T replica pg_isready -U moodledbuser -d moodle >/dev/null 2>&1; then
    break
  fi
  if [[ "${attempt}" -eq 60 ]]; then
    fail "read replica PostgreSQL did not become ready"
  fi
  sleep 2
done

"${COMPOSE[@]}" exec -T replica psql -v ON_ERROR_STOP=1 -U moodledbuser -d moodle \
  -c 'DROP SCHEMA public CASCADE; CREATE SCHEMA public AUTHORIZATION moodledbuser;' \
  || fail "could not prepare the replica database for restore"

"${COMPOSE[@]}" exec -T postgres pg_dump -U moodledbuser -d moodle --no-owner --no-privileges \
  | "${COMPOSE[@]}" exec -T replica psql -v ON_ERROR_STOP=1 -U moodledbuser -d moodle \
  || fail "could not copy the initialized Moodle database to the replica"

"${COMPOSE[@]}" exec -T replica psql -v ON_ERROR_STOP=1 -U moodledbuser -d moodle \
  -c 'ALTER DATABASE moodle SET default_transaction_read_only = on;' \
  || fail "could not mark the replica database read-only"

replica_id="$("${COMPOSE[@]}" ps -q replica)"
replica_ip="$(docker inspect --format '{{range .NetworkSettings.Networks}}{{.IPAddress}}{{end}}' "${replica_id}")"
[[ -n "${replica_ip}" ]] || fail "could not determine the read replica container IP"

assert_read_server "${replica_ip}" "Moodle routes new read queries to the recovered replica"

echo "Stopping the read replica to simulate a runtime outage..."
"${COMPOSE[@]}" stop replica
assert_read_server "${primary_ip}" "Moodle falls back to the primary after the replica fails"

echo "Restarting the read replica to simulate recovery..."
"${COMPOSE[@]}" start replica
for attempt in $(seq 1 60); do
  if "${COMPOSE[@]}" exec -T replica pg_isready -U moodledbuser -d moodle >/dev/null 2>&1; then
    break
  fi
  if [[ "${attempt}" -eq 60 ]]; then
    fail "read replica did not recover"
  fi
  sleep 2
done
assert_read_server "${replica_ip}" "Moodle resumes routing new read queries to the recovered replica"

echo "All container-based replica failover scenarios passed."
