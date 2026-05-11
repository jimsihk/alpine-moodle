#!/usr/bin/env bash
# Runs Moodle system checks via docker compose exec.
# Exits non-zero if critical errors are found (cron-only failures are ignored).
# Usage: source this file, then call wait_for_sut <compose-file>
# and/or check_moodle_system <compose-file>

wait_for_sut() {
  local COMPOSE_FILE="${1:-docker-compose.test.yml}"
  local SUT_EXIT=0
  local LOGS_PID

  docker compose --file "${COMPOSE_FILE}" logs --no-color -f sut &
  LOGS_PID=$!

  set +e
  docker compose --file "${COMPOSE_FILE}" wait sut
  SUT_EXIT=$?
  set -e

  kill "${LOGS_PID}" 2>/dev/null || true
  wait "${LOGS_PID}" 2>/dev/null || true

  return "${SUT_EXIT}"
}

check_moodle_system() {
  local COMPOSE_FILE="${1:-docker-compose.test.yml}"
  local CRON_CHECK_REF='tool_task_cronrunning'
  local CHECKS_OUTPUT CHECKS_EXIT NON_CRON_REFS HAS_CRON
  local CHECK_WAIT_SECONDS="${CHECK_MOODLE_SYSTEM_WAIT_SECONDS:-120}"
  CHECKS_EXIT=0
  echo "Waiting ${CHECK_WAIT_SECONDS}s before running Moodle system checks to exercise cron checks..."
  sleep "${CHECK_WAIT_SECONDS}"
  echo "Running Moodle system checks..."
  CHECKS_OUTPUT=$(docker compose --file "${COMPOSE_FILE}" exec -T app sh -c 'php -d max_input_vars=10000 "${WEB_PATH}"/admin/cli/checks.php' 2>&1) || CHECKS_EXIT=$?
  echo "${CHECKS_OUTPUT}"
  if [ "${CHECKS_EXIT}" -ge 2 ]; then
    NON_CRON_REFS=$(echo "${CHECKS_OUTPUT}" | sed -n 's/.*(\([A-Za-z0-9_-]*\)).*/\1/p' | sort -u | awk -v r="${CRON_CHECK_REF}" '$0!="" && $0!=r')
    HAS_CRON=$(echo "${CHECKS_OUTPUT}" | sed -n 's/.*(\([A-Za-z0-9_-]*\)).*/\1/p' | awk -v r="${CRON_CHECK_REF}" '$0==r{print "yes"}')
    if [ -z "${NON_CRON_REFS}" ] && [ -n "${HAS_CRON}" ]; then
      echo "Ignoring Moodle cron check failure in PR testing"
    else
      echo "Moodle system checks reported critical errors (exit code: ${CHECKS_EXIT})"
      return 1
    fi
  fi
}
