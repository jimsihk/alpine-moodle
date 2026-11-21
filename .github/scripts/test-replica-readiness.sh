#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
ENTRYPOINT="${ROOT_DIR}/rootfs/docker-entrypoint-init.d/02-configure-moodle.sh"
TEMP_DIR="$(mktemp -d)"
trap 'rm -rf "${TEMP_DIR}"' EXIT
READINESS_BLOCK="${TEMP_DIR}/readiness.sh"

# Exercise the actual readiness section from the entrypoint, not a duplicate
# implementation in the test.
awk '
  /^# Check that the database is available$/ { capture = 1 }
  capture { print }
  capture && /^sleep 3;$/ { exit }
' "${ENTRYPOINT}" > "${READINESS_BLOCK}"

grep -q '^while ! nc -w 1 "\$DB_HOST" "\$DB_PORT"; do$' "${READINESS_BLOCK}"
grep -q '^  if nc -w 1 "\$DB_HOST_REPLICA" "\$REPLICA_PORT" </dev/null; then$' "${READINESS_BLOCK}"
grep -q '^    echo "WARNING: Read replica .*continuing startup with the primary database" >&2$' "${READINESS_BLOCK}"

fail() {
  echo "FAIL: $*" >&2
  exit 1
}

assert_file_contains() {
  local file="$1" expected="$2"
  grep -Fq -- "${expected}" "${file}" || fail "expected '${expected}' in ${file}"
}

assert_text_contains() {
  local text="$1" expected="$2"
  [[ "${text}" == *"${expected}"* ]] || fail "expected '${expected}' in output: ${text}"
}

assert_call_count() {
  local expected="$1" actual
  actual="$(wc -l < "${CALL_LOG}")"
  [[ "${actual}" -eq "${expected}" ]] || fail "expected ${expected} TCP probes, got ${actual}: $(cat "${CALL_LOG}")"
}

# The mock records every TCP probe and can make the primary fail once or the
# optional replica fail consistently. Sleep is disabled to keep the test fast.
nc() {
  printf '%s:%s\n' "${3}" "${4}" >> "${CALL_LOG}"
  if [[ "${3}" == "${DB_HOST}" && "${4}" == "${DB_PORT}" ]]; then
    PRIMARY_ATTEMPTS=$((PRIMARY_ATTEMPTS + 1))
    if [[ "${PRIMARY_FAIL_FIRST:-false}" == 'true' && "${PRIMARY_ATTEMPTS}" -eq 1 ]]; then
      return 1
    fi
    return 0
  fi
  if [[ -n "${DB_HOST_REPLICA:-}" && "${3}" == "${DB_HOST_REPLICA}" && "${4}" == "${EXPECTED_REPLICA_PORT}" ]]; then
    REPLICA_ATTEMPTS=$((REPLICA_ATTEMPTS + 1))
    [[ "${REPLICA_AVAILABLE:-false}" == 'true' ]]
    return
  fi
  fail "unexpected nc invocation: $*"
}

sleep() { :; }

run_case() (
  local name="$1" expected_calls="$2"
  shift 2
  export DB_HOST='primary-db' DB_PORT='5432'
  export DB_HOST_REPLICA='' DB_PORT_REPLICA=''
  export REPLICA_AVAILABLE='false' PRIMARY_FAIL_FIRST='false'
  export CALL_LOG="${TEMP_DIR}/${name}.calls"
  local stderr="${TEMP_DIR}/${name}.stderr"
  PRIMARY_ATTEMPTS=0
  REPLICA_ATTEMPTS=0
  : > "${CALL_LOG}"

  while (($#)); do
    case "$1" in
      replica=*) export DB_HOST_REPLICA="${1#replica=}" ;;
      replica_port=*) export DB_PORT_REPLICA="${1#replica_port=}" ;;
      replica_available=*) export REPLICA_AVAILABLE="${1#replica_available=}" ;;
      primary_fail_first=*) export PRIMARY_FAIL_FIRST="${1#primary_fail_first=}" ;;
      *) fail "unknown test option: $1" ;;
    esac
    shift
  done
  EXPECTED_REPLICA_PORT="${DB_PORT_REPLICA:-$DB_PORT}"
  export EXPECTED_REPLICA_PORT

  local output
  output="$(source "${READINESS_BLOCK}" 2>"${stderr}")" || fail "${name}: readiness block returned non-zero"
  assert_call_count "${expected_calls}"
  assert_file_contains "${CALL_LOG}" 'primary-db:5432'
  assert_text_contains "${output}" 'primary-db is ready'

  if [[ -n "${DB_HOST_REPLICA}" && "${REPLICA_AVAILABLE}" == 'true' ]]; then
    assert_text_contains "${output}" "Read replica ${DB_HOST_REPLICA}:${EXPECTED_REPLICA_PORT} is reachable"
    [[ ! -s "${stderr}" ]] || fail "${name}: unexpected stderr: $(cat "${stderr}")"
  elif [[ -n "${DB_HOST_REPLICA}" ]]; then
    assert_file_contains "${stderr}" "WARNING: Read replica ${DB_HOST_REPLICA}:${EXPECTED_REPLICA_PORT} is not reachable; continuing startup with the primary database"
  else
    [[ ! -s "${stderr}" ]] || fail "${name}: unexpected stderr: $(cat "${stderr}")"
  fi

  printf '%s\n' "PASS: ${name}"
)

run_case 'no-replica' 1
run_case 'replica-reachable' 2 replica=replica-db replica_port=6432 replica_available=true
assert_file_contains "${TEMP_DIR}/replica-reachable.calls" 'replica-db:6432'
run_case 'replica-unavailable' 2 replica=replica-db replica_available=false
assert_file_contains "${TEMP_DIR}/replica-unavailable.calls" 'replica-db:5432'
run_case 'primary-waits-before-replica' 3 replica=replica-db replica_available=true primary_fail_first=true
[[ "$(sed -n '1p' "${TEMP_DIR}/primary-waits-before-replica.calls")" == 'primary-db:5432' ]] || fail 'primary probe was not first'
[[ "$(sed -n '2p' "${TEMP_DIR}/primary-waits-before-replica.calls")" == 'primary-db:5432' ]] || fail 'replica was probed before primary became ready'
[[ "$(sed -n '3p' "${TEMP_DIR}/primary-waits-before-replica.calls")" == 'replica-db:5432' ]] || fail 'replica probe did not follow primary readiness'

echo 'All replica readiness tests passed.'
