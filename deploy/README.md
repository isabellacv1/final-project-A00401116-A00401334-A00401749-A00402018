# Deployment (HU-13)

Automated deployment of the CircleGuard components to the AWS environments,
using the Docker images published by the CI pipeline.

## How it works

```
Jenkins (branch dev) ── Publish images ──► Nexus registry :8082
                                             │  circleguard/<service>:<version>
                                             ▼
                              Deploy (SSH to the environment)
                              docker compose pull + up -d --wait
                                             │
                                             ▼
                              Verify deployment (HTTP, with retries)
```

- **Images, not sources:** the target host never builds anything. It pulls the
  exact images published by the same build (`<version>` comes from `resolveVersion()`,
  never `latest`).
- **Configuration as variables:** everything environment specific lives in
  `deploy/environments/<environment>.env` and is read by the deploy step.
- **Verification:** the build only succeeds if every component answers over HTTP.

## Files

| File | Purpose |
|------|---------|
| `docker-compose.yml` | Application layer: the six components pulling `${REGISTRY}/circleguard/*:${VERSION}`. |
| `environments/dev.env` | `dev` environment: host, registry, Spring profile, web host. |
| `environments/stage.env` | `stage` environment (same keys). |
| `environments/prod.env` | `prod` environment (same keys). |

The infrastructure layer (`docker-compose.dev.yml` at the repository root, with
PostgreSQL, Neo4j, Kafka, Redis, Zookeeper and OpenLDAP and their healthchecks)
is copied to the host together with `init-db.sql`, and both files are combined:

```bash
docker compose -f docker-compose.dev.yml -f deploy/docker-compose.yml up -d --wait
```

## Environment variables

| Variable | Source | Meaning |
|----------|--------|---------|
| `HOST` | environment file | Public IP of the AWS instance. |
| `SSH_USER` | environment file | SSH user (`ubuntu`). |
| `REGISTRY` | environment file | Registry the hosts pull from (`100.31.132.57:8082`, the hosts have it in `insecure-registries`). |
| `SPRING_PROFILES_ACTIVE` | environment file | Spring profile of the components. |
| `WEB_HOST` | environment file | Address used by the browser to reach the published ports. |
| `VERSION` | pipeline | Semantic version of the images published by this build. |

## Requirements on the target host

- Docker Engine with the registry in `/etc/docker/daemon.json`:
  `"insecure-registries": ["100.31.132.57:8082"]` (no TLS on the registry connector).
- The Jenkins credential `<environment>-credential` (SSH key of the `ubuntu` user):
  `dev-credential`, `stage-credential`, `prod-credential`.

## Manual execution

```bash
# from the repository root, with REGISTRY and VERSION set
docker compose -f docker-compose.dev.yml -f deploy/docker-compose.yml config   # validate
docker compose -f docker-compose.dev.yml -f deploy/docker-compose.yml up -d --wait
```
