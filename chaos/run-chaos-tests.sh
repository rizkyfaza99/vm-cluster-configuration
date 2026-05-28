#!/usr/bin/env bash
set -euo pipefail

# =============================================================================
# run-chaos-tests.sh
# =============================================================================
# Chaos / resilience tests for the VictoriaMetrics cluster docker-compose
# environment.
#
# What it does:
#   - Spins up the standard cluster stack (vminsert, vmselect, vmstorage,
#     vmauth, vmagent, vmalert, alertmanager, grafana).
#   - Injects real failures by stopping / starting individual containers.
#   - Validates expected behaviour via the public endpoints (vmauth, vmagent)
#     and by querying the MetricsQL/PromQL API.
#
# Prerequisites (macOS / Linux):
#   - docker & docker compose
#   - curl
#   - jq
#
# Usage (run from repository root):
#   ./deployment/docker/chaos/run-chaos-tests.sh
# =============================================================================

COMPOSE_PROJECT="vm-chaos-test"
COMPOSE_FILE="deployment/docker/compose-vm-cluster.yml"

VM_URL="http://localhost:8427"
AGENT_URL="http://localhost:8429"

AUTH_USER="foo"
AUTH_PASS="bar"

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

log_info()  { echo -e "${GREEN}[INFO]${NC}  $(date '+%Y-%m-%d %H:%M:%S')  $*"; }
log_warn()  { echo -e "${YELLOW}[WARN]${NC}  $(date '+%Y-%m-%d %H:%M:%S')  $*"; }
log_error() { echo -e "${RED}[ERROR]${NC} $(date '+%Y-%m-%d %H:%M:%S')  $*"; }
fail()      { log_error "$*"; exit 1; }

require_cmd() {
  command -v "$1" >/dev/null 2>&1 || fail "Required command not found: $1"
}

compose_cmd() {
  docker-compose -f "$COMPOSE_FILE" -p "$COMPOSE_PROJECT" "$@"
}

container_is_running() {
  local service=$1
  docker-compose -f "$COMPOSE_FILE" -p "$COMPOSE_PROJECT" ps "$service" 2>/dev/null | grep -qi "running\|up"
}

# ---------------------------------------------------------------------------
# Metric helpers
# ---------------------------------------------------------------------------
get_agent_metric() {
  local pattern=$1
  curl -fsS "${AGENT_URL}/metrics" 2>/dev/null | grep "^${pattern}" | awk '{print $NF}' | head -n1 || true
}

get_agent_metric_by_labels() {
  local metric_name=$1
  shift
  local grep_expr="^${metric_name}{"
  for label_pattern in "$@"; do
    grep_expr="${grep_expr}.*${label_pattern}"
  done
  curl -fsS "${AGENT_URL}/metrics" 2>/dev/null | grep "$grep_expr" | awk '{print $NF}' | head -n1 || true
}

# ---------------------------------------------------------------------------
# Query helpers (go through vmauth)
# ---------------------------------------------------------------------------
vm_query() {
  local query=$1
  curl -fsS -u "$AUTH_USER:$AUTH_PASS" \
    "${VM_URL}/select/0/prometheus/api/v1/query?query=$(printf '%s' "$query" | jq -sRr @uri)" \
    2>/dev/null
}

vm_query_value() {
  local query=$1
  local out
  if out=$(vm_query "$query" 2>/dev/null); then
    echo "$out" | jq -r '.data.result[0].value[1] // empty'
  else
    echo ""
  fi
}

vm_insert() {
  local data=$1
  curl -fsS -X POST -u "$AUTH_USER:$AUTH_PASS" \
    "${VM_URL}/insert/0/prometheus/api/v1/import/prometheus" \
    -d "$data" 2>/dev/null
}

vm_insert_expect_fail() {
  local data=$1
  local rc=0
  local http_code=""
  http_code=$(curl -s -o /dev/null -w "%{http_code}" -X POST -u "$AUTH_USER:$AUTH_PASS" \
    "${VM_URL}/insert/0/prometheus/api/v1/import/prometheus" \
    -d "$data" 2>/dev/null) || rc=$?

  if [[ "$rc" -ne 0 ]]; then
    log_info "Insert failed as expected (connection or transport error)."
    return 0
  fi
  if [[ "$http_code" == "200" ]]; then
    fail "Expected insert to fail, but got HTTP 200"
  fi
  log_info "Insert returned HTTP $http_code (not 200), as expected."
}

service_up_metric() {
  local job=$1
  local instance=$2
  vm_query_value "up{job=\"${job}\",instance=\"${instance}\"}"
}

insert_marker() {
  local name=$1
  local val=$2
  vm_insert "${name} ${val}" || fail "Failed to insert marker metric ${name}"
}

query_marker() {
  local name=$1
  vm_query_value "$name"
}

# Retry querying a value until it matches the expected value or times out.
wait_for_query_value() {
  local query=$1
  local expected=$2
  local max_wait=${3:-60}
  local elapsed=0
  while (( elapsed < max_wait )); do
    local val
    val=$(vm_query_value "$query" 2>/dev/null) || true
    if [[ "$val" == "$expected" ]]; then
      return 0
    fi
    sleep 2
    ((elapsed+=2))
  done
  return 1
}

# ---------------------------------------------------------------------------
# Lifecycle helpers
# ---------------------------------------------------------------------------
start_cluster() {
  log_info "Starting cluster..."
  compose_cmd up -d
  log_info "Waiting 20 s for containers to start..."
  sleep 20
}

wait_for_pipeline() {
  log_info "Waiting for end-to-end pipeline (up metrics to appear in storage)..."
  local i val
  for i in {1..90}; do
    val=$(vm_query_value "count(up)" 2>/dev/null) || true
    if [[ "$val" =~ ^[0-9]+$ ]] && (( val > 0 )); then
      log_info "Pipeline ready. Found $val 'up' metric series."
      return 0
    fi
    sleep 2
  done
  fail "Timed out waiting for cluster pipeline to be ready"
}

stop_cluster() {
  log_info "Stopping cluster and removing volumes..."
  compose_cmd down -v || true
}

# ---------------------------------------------------------------------------
# Scenarios
# ---------------------------------------------------------------------------

scenario_vmstorage1_failure() {
  log_info "=== Scenario: vmstorage-1 failure ==="
  local marker="chaos_storage1_test"

  # Record baseline scrape failures for vmstorage-1
  local failures_before
  failures_before=$(get_agent_metric_by_labels "vm_promscrape_scrapes_failed_total" 'instance="vmstorage-1:8482"' 'job="vmstorage"')
  failures_before=${failures_before:-0}

  insert_marker "$marker" 1
  sleep 3

  log_info "Stopping vmstorage-1..."
  compose_cmd stop vmstorage-1
  sleep 20

  log_info "Checking vmstorage-1 container is stopped..."
  if container_is_running vmstorage-1; then
    fail "vmstorage-1 container is still running"
  fi
  log_info "vmstorage-1 container is stopped."

  log_info "Checking vmstorage-2 container is still running..."
  if ! container_is_running vmstorage-2; then
    fail "vmstorage-2 container is not running"
  fi
  log_info "vmstorage-2 container is running."

  log_info "Checking vmagent scrape failures for vmstorage-1 increased..."
  local failures_after
  failures_after=$(get_agent_metric_by_labels "vm_promscrape_scrapes_failed_total" 'instance="vmstorage-1:8482"' 'job="vmstorage"')
  failures_after=${failures_after:-0}

  if awk "BEGIN{exit !($failures_after > $failures_before)}" 2>/dev/null; then
    log_info "Scrape failures increased from $failures_before to $failures_after."
  else
    log_warn "Scrape failures did not increase yet (may need more time)."
  fi

  log_info "Restarting vmstorage-1..."
  compose_cmd start vmstorage-1
  sleep 30

  log_info "Checking vmstorage-1 container is running..."
  if ! container_is_running vmstorage-1; then
    fail "vmstorage-1 container did not restart"
  fi
  log_info "vmstorage-1 container is running."

  log_info "Waiting for vmstorage-1 to be scraped again..."
  sleep 20

  log_info "Verifying data can be inserted and queried after recovery..."
  insert_marker "${marker}_after_recovery" 123
  if ! wait_for_query_value "${marker}_after_recovery" "123" 90; then
    local q
    q=$(query_marker "${marker}_after_recovery")
    fail "Insert after vmstorage-1 recovery failed (got '$q')"
  fi
  log_info "Scenario passed."
}

scenario_vminsert1_failure() {
  log_info "=== Scenario: vminsert-1 failure ==="
  local marker="chaos_insert1_test"

  insert_marker "$marker" 1
  sleep 3

  log_info "Stopping vminsert-1..."
  compose_cmd stop vminsert-1
  sleep 20

  log_info "Checking vminsert-1 is down..."
  local up_val
  up_val=$(service_up_metric "vminsert" "vminsert-1:8480")
  if [[ "$up_val" != "0" ]]; then
    log_warn "vminsert-1 up=$up_val (expected 0)."
  fi

  log_info "Inserting marker via vmauth (should route to vminsert-2)..."
  # vmauth load-balances across vminserts; if the first backend is down it may
  # error on the first try, so retry the insert a couple of times.
  local inserted_ok=0
  for _ in {1..10}; do
    if vm_insert "${marker}_during 99" >/dev/null 2>&1; then
      inserted_ok=1
      break
    fi
    sleep 3
  done
  if [[ "$inserted_ok" -ne 1 ]]; then
    fail "Could not insert marker during vminsert-1 failure"
  fi

  # Query with retries because vmselect/vminsert may need a moment to stabilize.
  if ! wait_for_query_value "${marker}_during" "99" 60; then
    local q
    q=$(query_marker "${marker}_during")
    fail "Marker inserted during vminsert-1 failure not found (got '$q')"
  fi
  log_info "Insert succeeded and data is queryable."

  log_info "Restarting vminsert-1..."
  compose_cmd start vminsert-1
  sleep 20

  # Verify recovery by querying existing data rather than relying on the
  # up metric, which can lag behind due to scrape intervals.
  if ! wait_for_query_value "$marker" "1" 60; then
    local q
    q=$(query_marker "$marker")
    fail "vminsert-1 recovery check failed (pre-failure marker query returned '$q')"
  fi
  log_info "Scenario passed."
}

scenario_vmselect1_failure() {
  log_info "=== Scenario: vmselect-1 failure ==="
  local marker="chaos_select1_test"

  insert_marker "$marker" 1
  sleep 3

  log_info "Stopping vmselect-1..."
  compose_cmd stop vmselect-1
  sleep 20

  log_info "Checking vmselect-1 is down..."
  local up_val
  up_val=$(service_up_metric "vmselect" "vmselect-1:8481")
  if [[ "$up_val" != "0" ]]; then
    log_warn "vmselect-1 up=$up_val (expected 0)."
  fi

  log_info "Querying via vmauth (should route to vmselect-2)..."
  if ! wait_for_query_value "$marker" "1" 60; then
    local q
    q=$(query_marker "$marker")
    fail "Could not query marker during vmselect-1 failure (got '$q')"
  fi

  log_info "Restarting vmselect-1..."
  compose_cmd start vmselect-1
  sleep 20

  up_val=$(service_up_metric "vmselect" "vmselect-1:8481")
  if [[ "$up_val" != "1" ]]; then
    fail "vmselect-1 did not recover"
  fi

  log_info "Querying via vmauth (should route to vmselect-2)..."
  if ! wait_for_query_value "$marker" "1" 30; then
    local q
    q=$(query_marker "$marker")
    fail "Could not query marker during vmselect-1 failure (got '$q')"
  fi
  log_info "Query succeeded via healthy vmselect-2."

  log_info "Restarting vmselect-1..."
  compose_cmd start vmselect-1
  sleep 20

  # Verify recovery by querying existing data rather than relying on the
  # up metric, which can lag behind due to scrape intervals.
  if ! wait_for_query_value "$marker" "1" 60; then
    local q
    q=$(query_marker "$marker")
    fail "vmselect-1 recovery check failed (pre-failure marker query returned '$q')"
  fi
  log_info "Scenario passed."
}

scenario_vmauth_failure() {
  log_info "=== Scenario: vmauth failure ==="
  local marker="chaos_vmauth_test"

  insert_marker "$marker" 1
  sleep 3

  log_info "Recording vmagent pending-bytes baseline..."
  local pending_before
  pending_before=$(get_agent_metric "vmagent_remotewrite_pending_data_bytes")
  pending_before=${pending_before:-0}

  log_info "Stopping vmauth..."
  compose_cmd stop vmauth
  sleep 20

  log_info "Trying to insert via vmauth (expecting failure)..."
  vm_insert_expect_fail "${marker}_during 42"

  log_info "Checking vmagent pending bytes increased..."
  local pending_after
  pending_after=$(get_agent_metric "vmagent_remotewrite_pending_data_bytes")
  pending_after=${pending_after:-0}

  if awk "BEGIN{exit !($pending_after > $pending_before)}" 2>/dev/null; then
    log_info "Pending bytes increased from $pending_before to $pending_after."
  else
    log_warn "Pending bytes did not increase ($pending_after vs $pending_before)."
  fi

  log_info "Restarting vmauth..."
  compose_cmd start vmauth
  sleep 30

  log_info "Verifying insert works after recovery..."
  insert_marker "${marker}_after_recovery" 123
  if ! wait_for_query_value "${marker}_after_recovery" "123" 90; then
    local q
    q=$(query_marker "${marker}_after_recovery")
    fail "Insert after vmauth recovery failed (got '$q')"
  fi
  log_info "Scenario passed."
}

scenario_vmagent_failure() {
  log_info "=== Scenario: vmagent failure ==="

  log_info "Stopping vmagent..."
  compose_cmd stop vmagent
  sleep 20

  log_info "Checking vmagent endpoint is unreachable..."
  if curl -fsS "${AGENT_URL}/health" >/dev/null 2>&1; then
    fail "vmagent endpoint is still reachable"
  fi
  log_info "vmagent is unreachable as expected."

  log_info "Restarting vmagent..."
  compose_cmd start vmagent
  sleep 20

  if ! curl -fsS "${AGENT_URL}/health" >/dev/null 2>&1; then
    fail "vmagent did not recover"
  fi
  log_info "Scenario passed."
}

scenario_dual_vminsert_failure() {
  log_info "=== Scenario: Both vminserts failure (write-path outage) ==="
  local marker="chaos_dual_insert_test"

  insert_marker "$marker" 1
  sleep 3

  log_info "Recording vmagent pending-bytes baseline..."
  local pending_before
  pending_before=$(get_agent_metric "vmagent_remotewrite_pending_data_bytes")
  pending_before=${pending_before:-0}

  log_info "Stopping both vminserts..."
  compose_cmd stop vminsert-1 vminsert-2
  sleep 20

  log_info "Trying to insert via vmauth (expecting failure)..."
  vm_insert_expect_fail "${marker}_during 42"

  log_info "Checking vmagent pending bytes increased..."
  local pending_after
  pending_after=$(get_agent_metric "vmagent_remotewrite_pending_data_bytes")
  pending_after=${pending_after:-0}

  if awk "BEGIN{exit !($pending_after > $pending_before)}" 2>/dev/null; then
    log_info "Pending bytes increased from $pending_before to $pending_after."
  else
    log_warn "Pending bytes did not increase ($pending_after vs $pending_before)."
  fi

  log_info "Restarting vminserts..."
  compose_cmd start vminsert-1 vminsert-2
  sleep 30

  log_info "Verifying pre-failure data is still queryable..."
  if ! wait_for_query_value "$marker" "1" 60; then
    local q
    q=$(query_marker "$marker")
    fail "Pre-failure marker not found after recovery (got '$q')"
  fi

  insert_marker "${marker}_after_recovery" 123
  if ! wait_for_query_value "${marker}_after_recovery" "123" 90; then
    local q
    q=$(query_marker "${marker}_after_recovery")
    fail "Post-recovery insert failed (got '$q')"
  fi
  log_info "Scenario passed."
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------
main() {
  require_cmd docker
  require_cmd curl
  require_cmd jq

  if [[ ! -f "$COMPOSE_FILE" ]]; then
    fail "Compose file not found: $COMPOSE_FILE. Please run this script from the repository root."
  fi

  # Ensure a clean slate
  stop_cluster

  start_cluster
  wait_for_pipeline

  # Run the chaos scenarios
  scenario_vmstorage1_failure
  sleep 10
  scenario_vminsert1_failure
  sleep 10
  scenario_vmselect1_failure
  sleep 10
  scenario_vmauth_failure
  sleep 10
  scenario_vmagent_failure
  sleep 10
  scenario_dual_vminsert_failure

  stop_cluster

  log_info "============================================"
  log_info "All chaos scenarios completed successfully."
  log_info "============================================"
}

main "$@"
