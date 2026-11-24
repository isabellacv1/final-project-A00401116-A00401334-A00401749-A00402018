# Deployment (HU-13)

Automated deployment of the CircleGuard components to the AWS environments,
using the Docker images published by the CI pipeline.

## How it works

```
Jenkins (branch dev)
  -> Publish images -> Nexus registry :8082
                       circleguard/<service>:<version>
  -> Deploy (SSH to the environment)
       docker compose pull + up -d --wait
  -> Verify deployment (HTTP, with retries)
```

- **Images, not sources:** the target host never builds anything. It pulls the
  exact images published by the same build (`<version>` comes from `resolveVersion()`,
  never `latest`).
- **Configuration as variables (HU-34):** everything environment specific lives in
  `deploy/environments/<environment>.env` and every credential in the Jenkins
  credential `<environment>-app-secrets` (never versioned). The same image runs in
  all three environments.
- **Verification:** the build only succeeds if every component answers over HTTP.

## Files

| File | Purpose |
|------|---------|
| `docker-compose.yml` | Application layer: the nine components pulling `${REGISTRY}/circleguard/*:${VERSION}`. |
| `environments/dev.env` | `dev` environment: host, registry, Spring profile, web host, log level, token expirations. |
| `environments/stage.env` | `stage` environment (same keys). |
| `environments/prod.env` | `prod` environment (same keys). |
| `secrets/secrets.env.example` | Template of the secret contract (names only, no values). |
| `secrets/<environment>-secrets.env` | Real credentials for local runs. **Not versioned**. Deployed environments get them from Jenkins (see below). |

The infrastructure layer (`docker-compose.dev.yml` at the repository root, with
PostgreSQL, Neo4j, Kafka, Redis, Zookeeper and OpenLDAP and their healthchecks)
is copied to the host together with `init-db.sql`, and both files are combined:

```bash
docker compose -f docker-compose.dev.yml -f deploy/docker-compose.yml up -d --wait
```

## Environment variables

Non-sensitive values, one file per environment in `deploy/environments/`:

| Variable | Meaning |
|----------|---------|
| `HOST` | Public IP of the AWS instance. |
| `SSH_USER` | SSH user (`ubuntu`). |
| `REGISTRY` | Registry the hosts pull from (`100.31.132.57:8082`, present in `insecure-registries`). |
| `SPRING_PROFILES_ACTIVE` | Spring profile. Reserved: no `application-<profile>.yml` exists yet, so it changes nothing today. |
| `WEB_HOST` | Address used by the browser; also builds `CORS_ALLOWED_ORIGINS` as `http://${WEB_HOST}:8081`. |
| `LOG_LEVEL` | `DEBUG` in dev, `INFO` in stage, `WARN` in prod. |
| `JWT_EXPIRATION` | Token validity in **milliseconds** (`7200000` dev, `3600000` stage, `1800000` prod). |
| `QR_EXPIRATION` | QR validity in **milliseconds** (`60000`). |
| `DB_HOST`, `DB_PORT` | PostgreSQL endpoint inside the Docker network (`postgres`, `5432`). |
| `VERSION` | Semantic version of the images published by this build. Written by the pipeline, not stored in the file. |

Optional overrides with in-network defaults: `KAFKA_BOOTSTRAP_SERVERS`
(`kafka:29092`), `REDIS_HOST` (`redis`), `REDIS_PORT` (`6379`), `NEO4J_URI`
(`bolt://neo4j:7687`), `LDAP_URL` (`ldap://openldap:389`), `LDAP_BASE`,
`LDAP_USERNAME`, `IDENTITY_API_URL`, `AUTH_API_URL`,
`CIRCLEGUARD_PROMOTION_SERVICE_URL`, `FILE_STORAGE_PATH` (`/app/uploads`).

Secrets, in the Jenkins credential `<environment>-app-secrets` (locally,
`deploy/secrets/<environment>-secrets.env`):

| Variable | Consumed by |
|----------|-------------|
| `JWT_SECRET` | `auth` signs, `identity` and `promotion` validate. At least 32 bytes. |
| `QR_SECRET` | `auth` issues the QR, `gateway` validates it. At least 32 bytes. |
| `DB_PASSWORD` (+ `DB_USERNAME`) | PostgreSQL container and the five services with a database. |
| `NEO4J_PASSWORD` (+ `NEO4J_USERNAME`) | Neo4j container and `promotion`. |
| `LDAP_PASSWORD` | OpenLDAP admin and `auth`. |
| `VAULT_SECRET`, `VAULT_SALT`, `VAULT_HASH_SALT` | `identity`. |

`${VAR:?message}` in the compose files makes Compose fail **before** creating any
container when a secret is missing, instead of booting a service with an empty
password.

## Secrets on the host

Compose reads a single environment file per project, so the deploy step
(`deployEnvironment` in the pipeline library) builds it from the two sources:

1. `deploy/environments/<environment>.env` (versioned, includes `REGISTRY`) plus `VERSION`
   from the build.
2. The Jenkins **Secret file** credential `<environment>-app-secrets`
   (`dev-app-secrets`, `stage-app-secrets`, `prod-app-secrets`), a `KEY=VALUE` file
   that follows `secrets/secrets.env.example`. It is appended in the shell, so it
   never goes through Groovy or the console log; Windows line endings (`\r`) are
   removed.

The merged file is copied to the host as `circleguard/.env` with `600` permissions,
and the copy in the Jenkins workspace is deleted. Nothing is kept on the host
besides that `.env`: the next deploy overwrites it with the current credential.

To rotate a secret, update the Jenkins credential and run the deploy again. The
images are not rebuilt. If the credential is missing, the build fails at the
deploy stage, and if a variable is empty, Compose rejects it (`${VAR:?}`).

## Requirements on the target host

- Docker Engine with the registry in `/etc/docker/daemon.json`:
  `"insecure-registries": ["100.31.132.57:8082"]` (no TLS on the registry connector).
- The Jenkins credential `<environment>-credential` (SSH key of the `ubuntu` user):
  `dev-credential`, `stage-credential`, `prod-credential`.
- The Jenkins credential `<environment>-app-secrets` (Secret file) with every
  variable of `secrets/secrets.env.example` filled in.

## Manual execution

```bash
# from the repository root, with REGISTRY, VERSION and the secrets exported
docker compose -f docker-compose.dev.yml -f deploy/docker-compose.yml config --quiet   # validate
docker compose -f docker-compose.dev.yml -f deploy/docker-compose.yml up -d --wait
```

`config --quiet` validates the interpolation without printing the resolved values
(the full `config` output includes the secrets).
