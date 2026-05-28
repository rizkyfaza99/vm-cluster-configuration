# Chaos Testing Guide - VictoriaMetrics Cluster (Docker Compose)

> **Scope:** Validate the resilience of the standard `compose-vm-cluster.yml` stack by stopping individual (and groups of) containers and asserting expected degradation / recovery behaviour.
>
> **Environment:** This guide targets the Docker Compose cluster deployment. All commands are executed from the repository root.

---

## 1. Prerequisites

| Tool | Purpose |
|------|---------|
| `docker` + `docker compose` | Orchestrate the cluster |
| `curl` | Send HTTP requests to APIs |
| `jq` | Parse JSON responses from MetricsQL/PromQL queries |

On macOS these are typically available via Homebrew:

```bash
brew install docker curl jq
```

---

## 2. Quick Start

Run the automated chaos suite:

```bash
# From the repository root
./deployment/docker/chaos/run-chaos-tests.sh
```

The script will:

1. Start a **fresh** cluster (`docker compose up -d`).
2. Wait until the ingestion -> storage -> query pipeline is live.
3. Execute a series of failure scenarios (see below).
4. Tear the cluster down and remove volumes.

> **Warning:** This destroys existing `vm-chaos-test` project data. Do **not** run it against a production or long-lived environment.

---

## 3. Architecture Under Test

```
  vmagent (8429) --> vmauth (8427) --> vminsert-1 / vminsert-2 --> vmstorage-1 / vmstorage-2
                          ^                                              |
                          |                                              |
  Grafana (3000) ---------|<---------- vmselect-1 / vmselect-2 <---------|
```

* **vmagent** scrapes targets (including itself) and remote-writes through **vmauth**.
* **vmauth** load-balances reads (`/select/*`) across **vmselects** and writes (`/insert/*`) across **vminserts**.
* **vminsert** shards incoming data evenly across **vmstorage** nodes.
* **vmselect** queries all **vmstorage** nodes and merges partial results.

There is **no replication** in the default compose file, so a single `vmstorage` outage causes a 50 % shard to become unavailable for *new* writes and *existing* queries for that shard.

---

## 4. Test Plan

### 4.1 Single-Point Failures

| ID | Scenario | Injected Fault | Expected System Behaviour |
|---|---|---|---|
| S1 | **vmstorage-1 down** | `docker compose stop vmstorage-1` | - `up{job="vmstorage",instance="vmstorage-1:8482"} == 0`<br>- `up{job="vmstorage",instance="vmstorage-2:8482"} == 1`<br>- New metrics hashed to vmstorage-1 are **dropped** (no replication).<br>- Queries for metrics on vmstorage-2 still succeed.<br>- **vminsert** and **vmselect** RPC error counters rise.<br>- After restart, vmstorage-1 rejoins the cluster. |
| S2 | **vminsert-1 down** | `docker compose stop vminsert-1` | - `up{job="vminsert",instance="vminsert-1:8480"} == 0`<br>- **vmauth** eventually detects the dead backend and routes all insert traffic to **vminsert-2**.<br>- No data loss; ingestion continues at reduced capacity.<br>- After restart, vminsert-1 is re-added to the rotation. |
| S3 | **vmselect-1 down** | `docker compose stop vmselect-1` | - `up{job="vmselect",instance="vmselect-1:8481"} == 0`<br>- **vmauth** routes all read queries to **vmselect-2**.<br>- Grafana / API queries remain available.<br>- After restart, vmselect-1 resumes serving traffic. |
| S4 | **vmauth down** | `docker compose stop vmauth` | - All reads and writes through port `8427` fail (connection refused).<br>- **vmagent** cannot remote-write; its persistent queue (`vmagent_remotewrite_pending_data_bytes`) grows.<br>- Grafana cannot query data.<br>- After restart, vmagent flushes the queue and normal operation resumes. |
| S5 | **vmagent down** | `docker compose stop vmagent` | - `localhost:8429` becomes unreachable.<br>- No new scrapes are performed; all target `up` series stop being updated (become stale).<br>- Ingestion into the cluster stops entirely.<br>- After restart, scraping and remote-write resume. |

### 4.2 Multi-Point / Cascading Failures

| ID | Scenario | Injected Fault | Expected System Behaviour |
|---|---|---|---|
| M1 | **Both vminserts down** | `docker compose stop vminsert-1 vminsert-2` | - Complete **write-path outage**.<br>- vmagent queue grows continuously.<br>- No data is ingested.<br>- After restart, queued data is flushed and queryable. |
| M2 | **Both vmselects down** | `docker compose stop vmselect-1 vmselect-2` | - Complete **read-path outage**.<br>- Grafana and API queries fail.<br>- Ingestion is **unaffected** (writes continue through vminsert). |
| M3 | **vmauth + vmalert down** | `docker compose stop vmauth vmalert` | - No reads, no writes, no alert evaluation.<br>- vmagent queue grows.<br>- Recording rules stop being produced.<br>- Alert notifications cannot be delivered. |

### 4.3 Recovery & Durability

| ID | Scenario | Expected Pass Criteria |
|---|---|---|
| R1 | **vmstorage-1 stopped 60 s, then restarted** | After restart `up == 1` within 30 s. Pre-failure data is still queryable. Data inserted during the outage for the affected shard is **expected to be lost** (acceptable because replication is disabled). |
| R2 | **vmauth stopped 60 s, then restarted** | After restart, vmagent queue flushes. No data loss if queue size remained below disk limit. |
| R3 | **vminsert-1 stopped 60 s, then restarted** | No data loss. All inserts during the outage are handled by vminsert-2. |

---

## 5. Key Metrics to Watch During Chaos

You can observe the following metrics (exposed by each component on its `/metrics` endpoint) to reason about the blast radius of a failure.

| Metric | Exposed By | Meaning During Disruption |
|---|---|---|
| `up{job="..."}` | vmagent (scraped) | `0` = target unreachable. |
| `vm_rpc_connection_errors_total` | vminsert, vmselect | Increases when a vmstorage node is unreachable. |
| `vm_rpc_dial_errors_total` | vminsert, vmselect | Increases when RPC handshake to vmstorage fails. |
| `vmagent_remotewrite_pending_data_bytes` | vmagent | Grows when remote-write destination (vmauth / vminsert) is unavailable. |
| `vmagent_remotewrite_retries_count_total` | vmagent | Grows when blocks need to be retransmitted. |
| `vm_http_request_errors_total` | vmauth, vmselect, vminsert | Increases if a component returns errors to clients. |
| `vm_rows_inserted_total` | vminsert | Flatlines if ingestion stops completely. |
| `process_start_time_seconds` | all | Used by the `TooManyRestarts` alert. |

> **Tip:** You can open a second terminal and run a watch loop while the chaos script is executing:
>
> ```bash
> watch -n 2 'curl -s http://localhost:8429/metrics | grep vmagent_remotewrite_pending_data_bytes'
> ```

---

## 6. How to Extend the Tests

### 6.1 Add a New Scenario

Open `run-chaos-tests.sh` and add a shell function:

```bash
scenario_my_failure() {
  log_info "=== Scenario: My custom failure ==="
  local marker="chaos_custom_test"

  insert_marker "$marker" 1
  sleep 3

  # --- inject fault ---
  compose_cmd stop <service>
  sleep 15

  # --- validate ---
  local q
  q=$(query_marker "$marker")
  if [[ "$q" != "1" ]]; then
    fail "Marker missing during failure (got '$q')"
  fi

  # --- recover ---
  compose_cmd start <service>
  sleep 15

  log_info "Scenario passed."
}
```

Then register it in `main()`:

```bash
scenario_my_failure
```

### 6.2 Introduce Latency Instead of a Hard Stop

If you want to simulate slow networks rather than dead containers, use the [`toxiproxy`](https://github.com/Shopify/toxiproxy) Docker image or Linux `tc` inside a custom sidecar container. The `run-chaos-tests.sh` script can be adapted to call `docker exec ... tc qdisc add ...` on a target container's network interface.

### 6.3 Enable Replication and Re-Run

Edit `compose-vm-cluster.yml` and add `-replicationFactor=2` to **vminsert** and **vmselect** commands. With replication enabled, the expectations in **S1** change:

* **vmstorage-1 down** -> **no data loss** because every metric is written to two storages.
* **vmselect** with `-dedup.minScrapeInterval=1ms` will deduplicate replicas.

Update the assertions in `scenario_vmstorage1_failure` accordingly.

---

## 7. Cleanup & Safety

* The script always calls `compose_cmd down -v` at the end, which **removes named volumes** (`strgdata-1`, `strgdata-2`, `grafanadata`, etc.).
* If a scenario aborts halfway through, run the cleanup manually:

```bash
docker compose -f deployment/docker/compose-vm-cluster.yml -p vm-chaos-test down -v
```
* Do **not** point the chaos script at a production cluster. It deliberately destroys state to guarantee a clean test run.

---

## 8. Troubleshooting

| Symptom | Likely Cause | Fix |
|---|---|---|
| `vm_query_value` returns empty | Pipeline not warmed up yet | Increase sleep times or `wait_for_pipeline` retries. |
| `curl` returns `7` (connection refused) | Target container not fully started | Increase sleep after `compose_cmd start`. |
| vmauth still routes to dead backend | vmauth health-check removal takes time | Increase `sleep` after stopping a service (default script waits ~15 s). |
| `up` metric stays at `1` after stopping a target | vmagent hasn't scraped since the stop | Wait for the next scrape interval (10 s in `prometheus-vm-cluster.yml`). |

---

## 9. What Each Disrupted Resource Stops

When a resource is disrupted, the following metrics / capabilities are expected to be affected:

| Disrupted Resource | Metrics / Capabilities That Stop or Degrade |
|---|---|
| **vmstorage-1** | - `up{job="vmstorage",instance="vmstorage-1:8482"}` goes to `0`.<br>- 50 % of new time-series shards are **not stored** (data loss for that shard).<br>- Queries touching that shard return incomplete or partial results.<br>- `vm_rpc_connection_errors_total` on vminsert/vmselect increases. |
| **vminsert-1** | - `up{job="vminsert",instance="vminsert-1:8480"}` goes to `0`.<br>- Ingestion throughput drops by ~50 % until vmauth removes the backend.<br>- No data loss because vminsert-2 continues to accept writes. |
| **vmselect-1** | - `up{job="vmselect",instance="vmselect-1:8481"}` goes to `0`.<br>- Read latency may spike briefly while vmauth retries / removes the backend.<br>- No query data loss because vmselect-2 still serves all stored data. |
| **vmauth** | - All external reads and writes fail (port 8427 down).<br>- `vmagent_remotewrite_pending_data_bytes` grows as vmagent queues data.<br>- Grafana dashboards cannot load.<br>- vmalert cannot read or write state. |
| **vmagent** | - `up` metrics for **all** scrape targets stop updating (become stale).<br>- No new samples enter the cluster.<br>- vmagent's own `/metrics` endpoint is unreachable. |
| **vmalert** | - Alert evaluation halts; `vmalert_alerts_firing` stops updating.<br>- Recording rules stop producing new samples.<br>- Alertmanager receives no notifications. |
| **alertmanager** | - Alert notifications are black-holed (config in this repo routes to nowhere).<br>- `up{job="alertmanager"}` goes to `0`. |

---

*End of guide.*
