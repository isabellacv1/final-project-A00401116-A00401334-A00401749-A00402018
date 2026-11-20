# Load and failure evaluation report (HU-32)

> Fill in each section after running the tests. Commands and scenarios are described in
> [`tests/performance-locust/README.md`](../../tests/performance-locust/README.md).

## 1. Evaluation scenario

| Item | Value |
|------|-------|
| Environment | _dev / stage / prod_ |
| Host | _IP_ |
| Version under test | _image version, e.g. 1.0.0_ |
| Infrastructure | _instance type, number of nodes, Docker Compose or Kubernetes_ |
| Date | _yyyy-mm-dd_ |
| Locust | 2.32.4 |

Scenarios: access validation (weight 3) and survey submission (weight 1). Objectives: p95 ≤ 500 ms
per request type and error rate ≤ 1 %.

## 2. Load test results

| Profile | Users | Requests | Throughput (req/s) | Error rate | Objectives |
|---------|-------|----------|--------------------|------------|------------|
| smoke | 5 | | | | |
| load | 50 | | | | |
| stress | 200 | | | | |

p95 per request type (ms):

| Request | smoke | load | stress |
|---------|-------|------|--------|
| auth: login | | | |
| auth: generate QR | | | |
| gateway: validate QR | | | |
| form: submit survey | | | |

Observations: _where the latency grows, which request degrades first, errors seen._

## 3. Failure test results

| Failure | Errors while down | Time to recover | Behaviour observed |
|---------|-------------------|-----------------|--------------------|
| Stop Redis | | | |
| Stop promotion | | | |
| Stop identity | | | |
| Stop one prod node | | | |

## 4. Limitations and risks found

- _e.g. the gateway has no fallback when Redis is down, so the entrance stops validating._

## 5. Improvement opportunities

| Finding | Proposed improvement | Priority |
|---------|----------------------|----------|
| | _e.g. circuit breaker / retry with Resilience4j on the Redis call_ | |
| | _e.g. horizontal autoscaling (HPA) of the gateway_ | |
| | _e.g. cache of the health status in the gateway_ | |
