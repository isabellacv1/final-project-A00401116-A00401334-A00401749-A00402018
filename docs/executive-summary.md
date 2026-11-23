# CircleGuard — Executive Summary

**Team:** Melissa Hurtado Becerra, Isabella Cuervo Vargas, Valentina Tobar Gómez, Santiago Grajales Pérez
**Course:** Ingeniería de Software V, Universidad Icesi · **Period:** November 1–22, 2026

## Context

CircleGuard is a contact-tracing and health-fencing system for a university campus. It
detects groups of connected people ("Circles"), propagates risk statuses when someone tests
positive, and controls campus access with signed QR codes. It does this without exposing
students' identities. The system has eight Spring Boot microservices, a web/mobile client,
and PostgreSQL, Neo4j, Redis, Kafka and LDAP behind them.

The goal of the project was not to build new features. It was to take this existing
software **from a developer's commit to production through an automated, secure,
observable and reproducible process**.

## What we delivered

- **Agile delivery.** We used Scrum in three sprints with a Jira backlog of 13 epics and
  32 user stories. Every change goes through a protected-branch workflow: pull requests,
  peer review, Conventional Commits and required CI checks.
- **CI/CD pipeline.** Jenkins runs a reusable shared library. Each change is built, tested
  (unit, integration with Testcontainers, and end-to-end with Playwright), analyzed with
  SonarQube and scanned with Trivy. It is then published to Nexus as an immutable,
  semantically versioned image and deployed automatically. Semantic-release generates
  version tags and release notes.
- **Infrastructure as Code.** Terraform defines three independent Kubernetes (k3s)
  clusters on AWS for dev, stage and prod. Remote state is stored in S3 with locking,
  disks are encrypted and backed up daily, and Terraform changes are validated, scanned
  and applied from the pipeline.
- **Kubernetes deployment.** Kustomize overlays per environment, namespace isolation,
  quotas, network policies and least-privilege RBAC. The pipeline deploys the same
  version across environments, verifies it, and rolls back automatically if a deployment
  fails.
- **Observability.** Prometheus metrics, Grafana dashboards (services, infrastructure,
  business), nine alert rules, and centralized logs with Loki.
- **Design patterns.** External Configuration with no secrets in the repository;
  resilience through health probes, timeouts, retries and circuit breakers; zero-downtime
  Rolling Updates; a Canary release; and autoscaling of the gateway.
- **Documentation.** Architecture, operations manual, runbooks, test evidence and cost
  analysis.

## Results

| Before | After |
|---|---|
| Manual builds and deployments | Every merge is built, tested, scanned, versioned and deployed automatically |
| Secrets stored in the repository | Secrets injected per environment, outside Git |
| Hand-created servers | Reproducible infrastructure defined in Terraform |
| No visibility of production behavior | Dashboards, alerts and centralized logs |
| Releases with downtime and no way back | Rolling Updates, Canary and automatic rollback |

Infrastructure cost was kept within the **USD 150 budget** by choosing k3s instead of a
managed Kubernetes service (saving about USD 219/month), avoiding NAT gateways and load
balancers, and shutting instances down when idle. Actual usage from November 1 to 22 was
**USD 144.58 (96 % of the budget)**, 18 % above the estimate because instances stayed on
longer than planned. AWS credits covered it, so the net cost was USD 0.

## Pending work and recommendations

1. **Enable automatic promotion to stage and prod.** It is implemented but switched off
   until both clusters are validated.
2. **Add Alertmanager.** Alerts currently appear only on dashboards and do not notify
   anyone.
3. **Schedule logical database backups**, in addition to the daily disk snapshots.
4. **Remove the Part 1 servers** that Kubernetes has replaced, to cut recurring cost.

## Key lessons

Integrating small changes often worked better than integrating at the end of a sprint.
Treating infrastructure as code made errors visible early. Security scanning inside the
pipeline turned vulnerabilities into routine updates rather than last-minute emergencies.
