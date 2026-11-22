#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
PROJECT="replica-failover-${GITHUB_RUN_ID:-local}-${GITHUB_RUN_ATTEMPT:-1}"
COMPOSE=(docker compose --project-name "${PROJECT}" --file "${ROOT_DIR}/docker-compose.test.yml" --file "${ROOT_DIR}/docker-compose.test.replica.yml")

fail() {
  echo "FAIL: $*" >&2
  echo "::group::Recent container logs (last 80 lines per service)"
  "${COMPOSE[@]}" logs --timestamps --tail=80 app postgres pgbouncer replica pgbouncer-replica 2>/dev/null || true
  echo "::endgroup::"
  exit 1
}

declare -a SCENARIO_RESULTS=()

record_summary() {
  local scenario="$1" expected="$2" actual="$3"
  SCENARIO_RESULTS+=("${scenario}|${expected}|${actual}")
}

write_summary() {
  [[ -n "${GITHUB_STEP_SUMMARY:-}" ]] || return 0
  {
    echo "## Moodle database replica failover"
    echo
    echo "| Scenario | Expected database | Actual database | Result |"
    echo "|---|---|---|---|"
    for result in "${SCENARIO_RESULTS[@]}"; do
      IFS='|' read -r scenario expected actual <<< "${result}"
      echo "| ${scenario} | ${expected} | ${actual} | PASS |"
    done
  } >> "${GITHUB_STEP_SUMMARY}"
}

section() { echo "::group::$1"; }
end_section() { echo "::endgroup::"; }

cleanup() {
  "${COMPOSE[@]}" down --volumes --remove-orphans >/dev/null 2>&1 || true
}
trap cleanup EXIT

"${COMPOSE[@]}" config --quiet

export TEST_IMAGE_NAME="${TEST_IMAGE_NAME:-jimsihk/alpine-moodle:replica-failover-test}"

section "Build Moodle test image"
echo "Building application image (verbose BuildKit progress suppressed)..."
"${COMPOSE[@]}" build --quiet app
end_section

section "Start primary PostgreSQL, PgBouncer and Redis"
"${COMPOSE[@]}" up -d postgres pgbouncer redis
for attempt in $(seq 1 60); do
  if "${COMPOSE[@]}" exec -T postgres pg_isready -U moodledbuser -d moodle >/dev/null 2>&1; then
    break
  fi
  if [[ "${attempt}" -eq 60 ]]; then
    fail "primary PostgreSQL did not become ready"
  fi
  sleep 2
done
end_section

section "Start Moodle without the read replica"
"${COMPOSE[@]}" up -d --no-deps app

echo "Waiting for the installed Moodle homepage marker..."
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
end_section

section "Scenario 1: startup with replica unavailable"
"${COMPOSE[@]}" logs app | grep -F 'WARNING: Read replica pgbouncer-replica:5432 is not reachable; continuing startup with the primary database' >/dev/null \
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

assert_moodle_homepage() {
  local description="$1" homepage
  homepage="$("${COMPOSE[@]}" exec -T app wget -q -O - http://127.0.0.1:8080/ 2>/dev/null)" \
    || fail "${description}: Moodle homepage request failed"
  if [[ -z "${homepage//[[:space:]]/}" ]]; then
    fail "${description}: Moodle homepage response HTML was empty"
  fi
  if ! grep -Fq '>Dockerized_Moodle<' <<< "${homepage}"; then
    fail "${description}: Moodle homepage response HTML did not contain the expected installed-site marker"
  fi
  echo "PASS: ${description} (HTTP request succeeded and expected HTML marker was present)"
}

assert_read_server() {
  local expected="$1" description="$2" expected_name="$3" actual
  actual="$(read_server_ip)" || fail "${description}: Moodle database read query failed"
  if [[ "${actual}" != "${expected}" ]]; then
    fail "${description}: expected ${expected_name} database at ${expected}, got ${actual}"
  fi
  echo "PASS: ${description}"
  echo "  Expected: ${expected_name} (${expected})"
  echo "  Actual:   ${actual}"
  record_summary "${description}" "${expected_name} (${expected})" "${actual}"
}

# Moodle's default replica consistency window is one second. Allow the
# installation writes to settle before checking that a normal table read uses
# the replica-aware DML path.
assert_moodle_homepage "Moodle homepage works with replica unavailable at startup"
sleep 2
assert_read_server "${primary_ip}" "Startup with replica unavailable" "primary"
end_section

section "Start and prepare replica PostgreSQL"
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

"${COMPOSE[@]}" exec -T replica psql -q -v ON_ERROR_STOP=1 -U moodledbuser -d moodle \
  -c 'DROP SCHEMA public CASCADE; CREATE SCHEMA public AUTHORIZATION moodledbuser;' \
  || fail "could not prepare the replica database for restore"

"${COMPOSE[@]}" exec -T postgres pg_dump -U moodledbuser -d moodle --no-owner --no-privileges \
  | "${COMPOSE[@]}" exec -T replica psql -q -v ON_ERROR_STOP=1 -U moodledbuser -d moodle \
  || fail "could not copy the initialized Moodle database to the replica"

restored_table_count="$("${COMPOSE[@]}" exec -T replica psql -q -t -A -v ON_ERROR_STOP=1 -U moodledbuser -d moodle \
  -c "SELECT count(*) FROM information_schema.tables WHERE table_schema = 'public';" | tr -d '[:space:]')"
[[ "${restored_table_count}" =~ ^[0-9]+$ ]] && (( restored_table_count > 0 )) \
  || fail "replica snapshot restore completed without any public tables"

"${COMPOSE[@]}" exec -T replica psql -q -v ON_ERROR_STOP=1 -U moodledbuser -d moodle \
  -c 'ALTER DATABASE moodle SET default_transaction_read_only = on;' \
  || fail "could not mark the replica database read-only"

replica_id="$("${COMPOSE[@]}" ps -q replica)"
replica_ip="$(docker inspect --format '{{range .NetworkSettings.Networks}}{{.IPAddress}}{{end}}' "${replica_id}")"
[[ -n "${replica_ip}" ]] || fail "could not determine the read replica container IP"
echo "Replica snapshot restored and verified (${restored_table_count} public tables); database marked read-only."
end_section

section "Start replica PgBouncer after snapshot restore"
"${COMPOSE[@]}" up -d pgbouncer-replica
for attempt in $(seq 1 60); do
  if "${COMPOSE[@]}" exec -T app nc -w 1 pgbouncer-replica 5432 </dev/null >/dev/null 2>&1; then
    break
  fi
  if [[ "${attempt}" -eq 60 ]]; then
    fail "replica PgBouncer did not become reachable"
  fi
  sleep 1
done
end_section

section "Scenario 2: replica available through its own PgBouncer"
assert_moodle_homepage "Moodle homepage works after replica snapshot restore and PgBouncer startup"
assert_read_server "${replica_ip}" "Read routing while replica is healthy through PgBouncer" "replica"
end_section

replica_pgbouncer_id="$("${COMPOSE[@]}" ps -q pgbouncer-replica)"
replica_pgbouncer_ip="$(docker inspect --format '{{range .NetworkSettings.Networks}}{{.IPAddress}}{{end}}' "${replica_pgbouncer_id}")"
[[ -n "${replica_pgbouncer_ip}" ]] || fail "could not determine the replica PgBouncer container IP"

assert_replica_pgbouncer_stopped() {
  local container_id state
  container_id="$("${COMPOSE[@]}" ps --all -q pgbouncer-replica)"
  [[ -n "${container_id}" ]] || fail "replica PgBouncer container was not found"
  state="$(docker inspect --format '{{.State.Status}}' "${container_id}")"
  if [[ "${state}" != "exited" ]]; then
    fail "replica PgBouncer must be stopped before continuing; current state: ${state}"
  fi
  echo "PASS: replica PgBouncer is stopped (container state: ${state})"
}

section "Scenario 3: replica PgBouncer becomes unavailable"
# Take the replica endpoint offline. Check Moodle while the stop operation is
# in progress, then wait for Docker to finish stopping PgBouncer before testing
# fallback or allowing Scenario 4 to begin.
"${COMPOSE[@]}" stop pgbouncer-replica &
stop_pgbouncer_pid=$!
assert_moodle_homepage "Moodle homepage remains available while replica PgBouncer is stopping"
wait "${stop_pgbouncer_pid}" || fail "could not stop replica PgBouncer"
assert_replica_pgbouncer_stopped
assert_moodle_homepage "Moodle homepage remains available after replica PgBouncer stopped"
assert_read_server "${primary_ip}" "Read routing after replica PgBouncer outage" "primary"
end_section

section "Scenario 4: replica PgBouncer recovers"
# Do not begin recovery until Scenario 3 has confirmed the container is stopped.
assert_replica_pgbouncer_stopped
# Prove the application remains usable while the replica endpoint is still down.
assert_moodle_homepage "Moodle homepage remains available while replica recovery is pending"
assert_read_server "${primary_ip}" "Read routing while replica recovery is pending" "primary"

"${COMPOSE[@]}" start pgbouncer-replica
for attempt in $(seq 1 60); do
  if "${COMPOSE[@]}" exec -T app nc -w 1 pgbouncer-replica 5432 </dev/null >/dev/null 2>&1; then
    break
  fi
  if [[ "${attempt}" -eq 60 ]]; then
    fail "replica PgBouncer did not recover"
  fi
  if (( attempt % 5 == 0 )); then
    assert_moodle_homepage "Moodle homepage remains available while replica PgBouncer is starting"
  fi
  sleep 2
done

# Allow Moodle's replica consistency window to expire before checking routing.
sleep 2
assert_moodle_homepage "Moodle homepage remains available after replica recovery"
assert_read_server "${replica_ip}" "Read routing after replica recovery through PgBouncer" "replica"
end_section

section "Scenario 5: replica PgBouncer endpoint silently drops TCP connections"
# Keep the replica DNS record and container alive, but drop packets addressed
# to PgBouncer. This models a black-holed endpoint rather than a refused port.
"${COMPOSE[@]}" up -d replica-firewall
firewall_rule_ready=false
for attempt in $(seq 1 30); do
  if "${COMPOSE[@]}" exec -T replica-firewall iptables -C INPUT -p tcp --dport 5432 -j DROP >/dev/null 2>&1; then
    firewall_rule_ready=true
    break
  fi
  sleep 1
done
[[ "${firewall_rule_ready}" == true ]] || fail "replica firewall did not install the TCP DROP rule"

resolved_replica_ip="$("${COMPOSE[@]}" exec -T app php -r 'echo gethostbyname("pgbouncer-replica"), PHP_EOL;' | tr -d '\r')"
[[ "${resolved_replica_ip}" == "${replica_pgbouncer_ip}" ]] \
  || fail "replica DNS no longer resolves to the live PgBouncer endpoint (${resolved_replica_ip})"

if "${COMPOSE[@]}" exec -T app nc -w 1 pgbouncer-replica 5432 </dev/null >/dev/null 2>&1; then
  fail "replica PgBouncer TCP connection unexpectedly succeeded while packets were dropped"
fi
echo "PASS: replica DNS still resolves, but TCP connections to its live endpoint time out"

assert_moodle_homepage "Moodle homepage remains available while replica TCP connections are black-holed"
SECONDS=0
assert_read_server "${primary_ip}" "Read routing when replica TCP connections are black-holed" "primary"
if (( SECONDS > 10 )); then
  fail "Moodle fallback exceeded 10 seconds with the replica endpoint black-holed (${SECONDS}s)"
fi

"${COMPOSE[@]}" exec -T replica-firewall iptables -D INPUT -p tcp --dport 5432 -j DROP \
  || fail "could not remove the replica TCP DROP rule"
"${COMPOSE[@]}" stop replica-firewall >/dev/null \
  || fail "could not stop the replica firewall helper"
for attempt in $(seq 1 30); do
  if "${COMPOSE[@]}" exec -T app nc -w 1 pgbouncer-replica 5432 </dev/null >/dev/null 2>&1; then
    break
  fi
  if [[ "${attempt}" -eq 30 ]]; then
    fail "replica PgBouncer endpoint did not become reachable after removing the firewall rule"
  fi
  sleep 1
done
sleep 2
assert_moodle_homepage "Moodle homepage remains available after replica TCP connectivity recovers"
assert_read_server "${replica_ip}" "Read routing after replica TCP connectivity recovers" "replica"
end_section

section "Scenario 6: PgBouncer accepts clients while its PostgreSQL backend is unavailable"
# Stop only PostgreSQL. PgBouncer remains running and continues accepting TCP
# connections, but cannot establish a usable server connection for Moodle.
"${COMPOSE[@]}" stop replica >/dev/null \
  || fail "could not stop the replica PostgreSQL backend"
replica_state="$(docker inspect --format '{{.State.Status}}' "${replica_id}")"
[[ "${replica_state}" == "exited" ]] \
  || fail "replica PostgreSQL backend should be stopped (state: ${replica_state})"
"${COMPOSE[@]}" exec -T app nc -w 1 pgbouncer-replica 5432 </dev/null >/dev/null 2>&1 \
  || fail "PgBouncer frontend stopped accepting TCP connections with its backend unavailable"
echo "PASS: PgBouncer frontend accepts TCP connections while replica PostgreSQL is stopped"

assert_moodle_homepage "Moodle homepage remains available while PgBouncer has no PostgreSQL backend"
SECONDS=0
assert_read_server "${primary_ip}" "Read routing when PgBouncer backend is unavailable" "primary"
if (( SECONDS > 30 )); then
  fail "Moodle fallback exceeded 30 seconds while PgBouncer backend was unavailable (${SECONDS}s)"
fi

"${COMPOSE[@]}" start replica >/dev/null \
  || fail "could not restart the replica PostgreSQL backend"
for attempt in $(seq 1 60); do
  if "${COMPOSE[@]}" exec -T replica pg_isready -U moodledbuser -d moodle >/dev/null 2>&1; then
    break
  fi
  if [[ "${attempt}" -eq 60 ]]; then
    fail "replica PostgreSQL backend did not recover"
  fi
  sleep 2
done
sleep 2
assert_moodle_homepage "Moodle homepage remains available after replica PostgreSQL backend recovers"
assert_read_server "${replica_ip}" "Read routing after PgBouncer backend recovers" "replica"
end_section

write_summary
echo
echo "Replica failover result: 6/6 scenarios passed."
