# Load and failure tests (HU-32)

Load tests with [Locust](https://locust.io/) and failure injection to evaluate how CircleGuard behaves
under load and when a component fails.

| File | Purpose |
|------|---------|
| `locustfile.py` | The two scenarios and the check of the objectives. |
| `run-load-test.sh` | Runs a load profile without the web UI and saves CSV + HTML results. |
| `run-failure-test.sh` | Injects a failure during the load and records the timeline. |
| `requirements.txt` | Pinned Locust version. |

## Scenarios

| Scenario | Weight | Requests | Why |
|----------|--------|----------|-----|
| Access validation | 3 | `auth: generate QR` (renewed every 45 s, the QR lives 60 s) and `gateway: validate QR` | The most frequent operation on campus: every entrance validates a QR. |
| Survey submission | 1 | `form: submit survey` | Students report symptoms daily. |

Every simulated user logs in once (`auth: login`). Surveys are sent **without symptoms**: a
symptomatic report would mark the test user as SUSPECT and the gate would start denying access,
which would change what the access scenario measures.

A request counts as failed when the status code is not the expected one, or when a valid QR is not
accepted (`"valid": true`).

## Objectives

| Metric | Objective | Variable |
|--------|-----------|----------|
| p95 latency of each request type | ≤ 500 ms | `P95_TARGET_MS` |
| Error rate | ≤ 1 % | `MAX_ERROR_RATE` |
| Throughput | Reported (req/s), compared between profiles | — |

At the end of every run Locust prints an **Objectives** section and exits with code `0` when all
objectives are met and `1` otherwise.

## Profiles

| Profile | Users | Spawn rate | Duration | Use |
|---------|-------|------------|----------|-----|
| `smoke` | 5 | 1/s | 1 min | Check that the scenarios work. |
| `load` | 50 | 5/s | 5 min | Expected campus peak. |
| `stress` | 200 | 10/s | 5 min | Beyond the peak, to find the limit. |

## Running

The environment ports (8180, 8087, 8086) must be reachable from the machine that runs Locust. The
environment security groups only allow the Jenkins host, so either run it there or ask for your IP
to be allowed.

```bash
cd tests/performance-locust
python3 -m venv .venv && . .venv/bin/activate
pip install -r requirements.txt

export TARGET_HOST=<environment IP>
export LOAD_USERNAME=health_user
export LOAD_PASSWORD=<test user password>

./run-load-test.sh smoke     # first, a quick check
./run-load-test.sh load
./run-load-test.sh stress
```

Results are saved in `results/<profile>-<date>/`: `report.html` (charts), `stats_stats.csv`
(per request type) and `console.log` (including the Objectives section).

## Failure injection

`run-failure-test.sh` runs a constant load and, in the middle, executes a command that breaks a
component and later one that restores it:

```
|-- 2 min normal load --|-- 2 min with the failure --|-- 3 min after recovery --|
```

```bash
export FAILURE_CMD='ssh ubuntu@<ip> docker stop circleguard-redis'
export RECOVERY_CMD='ssh ubuntu@<ip> docker start circleguard-redis'
./run-failure-test.sh
```

`results/failure-<date>/stats_stats_history.csv` has one row per interval, so the error rate and
latency can be plotted over time. `timeline.txt` records when the failure and the recovery happened.

Suggested failures and what to look for:

| Failure | Expected impact | What to measure |
|---------|-----------------|-----------------|
| Stop Redis | The gateway cannot read the health status: QR validations fail | Error rate while it is down and time to recover after it starts again |
| Stop promotion | Surveys are still accepted (form only publishes to Kafka) | Whether the form keeps answering and whether the events are processed later |
| Stop identity | New logins fail (auth asks identity for the anonymous id) | Login errors vs. validations of users that were already logged in |
| Stop one prod node (Kubernetes) | Pods move to the other node | Downtime and errors during the rescheduling |

The results and the analysis go in [`docs/performance/load-and-failure-report.md`](../../docs/performance/load-and-failure-report.md).
