# CircleGuard Monorepo

**Absolute Privacy. High-Speed Containment. Secure Campus.**

CircleGuard is a state-of-the-art university contact tracing and fencing system designed to identify interconnected contact groups ("Circles") and apply rapid health fences while preserving individual anonymity.

---

## Vision & Mission

Our vision is a university campus where health containment speed outpaces lab confirmation timelines without compromising student privacy. CircleGuard leverages campus-native intelligence—class schedules and WiFi infrastructure—to deliver a human-validated, graph-based protection ecosystem.

### Key Differentiators
- **Privacy-as-Code**: Zero real-name exposure outside a secure Health Center vault.
- **Recursive Containment**: Status promotion cascades (Suspect → Probable → Confirmed) that trigger in milliseconds.
- **Campus Integration**: Smart check-ins using existing WiFi AP triangulation and Bluetooth Low Energy (BLE).

---

## Success Metrics

| Metric | Target | Measurement |
|:---|:---|:---|
| **Containment Speed** | < 60 Seconds | Automated test of promotion engine cascade |
| **Privacy Compliance** | 100% Anonymity | Penetration test on graph database (Zero real names) |
| **Check-in Adoption** | > 70% | Analytics on scheduled class contact validation |
| **False Positive Rate** | < 15% | Post-fence surveys of actual vs. suspected contact |
| **System Uptime** | 99.5% | 7:00 AM – 10:00 PM (Academic Peak Hours) |

---

## Architecture Overview

CircleGuard follows a **Microservice Architecture** built on a **Hybrid Data Model**.

### Core Engine
1. **Status Promotion Machine**: Uses **Neo4j** for recursive graph traversals to identify contacts within a 14-day temporal window.
2. **Anonymization Vault**: A segregated **PostgreSQL** vault handles salted-hash identity mapping, compliant with **FERPA** regulations.
3. **Event-Driven Core**: **Apache Kafka** manages asynchronous status changes, audit logs, and notification dispatches.

### Services Directory
- **Auth Service**: Dual-chain LDAP (University) / Local (Guest) auth with Dynamic RBAC.
- **Identity Service**: Cryptographic vault for anonymizing real identities.
- **Promotion Service**: The status engine (Recursive Graph Processing).
- **Notification Service**: Multi-channel dispatcher (Push/Email/SMS).
- **Form Service**: Dynamic health questionnaire engine.
- **Gateway Service**: Campus entry validation via signed, time-limited QR tokens.
- **Dashboard Service**: Geospatial hotspot analytics (Privacy-preserving).
- **File Service**: Secure certificate and document storage (S3-compatible).

---

## Technical Stack

| Layer | Technology | Rationale |
|:---|:---|:---|
| **Backend** | Spring Boot 4 / Java 21 | Enterprise-grade maturity & low-latency Jakarta EE support. |
| **Graph DB** | Neo4j 5.26 | High-performance recursive traversals unreachable with SQL. |
| **Relational DB**| PostgreSQL 16 | ACID compliant storage for identity and configuration. |
| **Message Bus** | Apache Kafka 7.6 | Persistent, audit-trailed event log for status dispatches. |
| **Caching** | Redis 7.2 | L2 distributed cache for rapid entry-gate status validation. |
| **Mobile/Web** | Expo (React Native) | Unified codebase across iOS, Android, and Browser. |
| **Infra** | Kubernetes | Orchestration for high availability and auto-scaling. |

---

## Roadmap

### Phase 1: MVP — The Intelligence Core (Current)
- [x] Status Promotion Machine (Suspect → Probable → Confirmed).
- [x] Temporal graph with 14-day TTL edges.
- [x] Multi-channel fence notifications (Push/Email/SMS).
- [ ] Health Center de-identification console.

### Phase 2: Growth — Spatial Intelligence
- [ ] WiFi AP triangulation integration.
- [ ] Campus entry validation (Gatekeeper) QR integration.
- [ ] LMS integration for "Remote Attendance" status automation.

### Phase 3: Vision — Full Ecosystem
- [ ] Off-campus circle detection via P2P Bluetooth.
- [ ] Global Health Dashboard with hotspot visualization.
- [ ] Lab API bridge for automated test result ingestion.

---

## Run Everything with Docker Compose

The whole platform (middleware, the five core services and the web app) can be started with one command. Only Docker (with Compose v2) is required — no Java or Node on the host.

```bash
docker compose -f docker-compose.dev.yml -f docker-compose.app.yml up -d --build
```

| File | Contents |
|:---|:---|
| `docker-compose.dev.yml` | Middleware: PostgreSQL, Neo4j, Zookeeper, Kafka, Redis, OpenLDAP (with healthchecks), the `circleguard-net` network and the `pgdata` / `neo4jdata` volumes. |
| `docker-compose.app.yml` | auth, identity, promotion, form, gateway and the web app, built from their Dockerfiles. |

The first build takes a few minutes. Services start in dependency order: each one waits until its databases / broker report healthy. Check progress with:
```bash
docker compose -f docker-compose.dev.yml -f docker-compose.app.yml ps
```
Everything is ready when all containers show `(healthy)`.

| Component | URL |
|:---|:---|
| Web app | http://localhost:8081 |
| Auth service | http://localhost:8180 |
| Identity service | http://localhost:8083 |
| Form service | http://localhost:8086 |
| Gateway service | http://localhost:8087 |
| Promotion service | http://localhost:8088 |
| Neo4j browser | http://localhost:7474 |

Test users (password `password`): `super_admin`, `staff_guard`, `health_user`.

**Networking notes**
- Inside `circleguard-net` containers reach each other by service name (`postgres`, `kafka`, `identity`, ...). Kafka exposes `kafka:29092` for containers and `localhost:9092` for apps on the host.
- The web app runs in the browser, so its `*_BASE_URL` variables use the ports published on `localhost`. It must be served on port 8081, the origin allowed by the services' CORS policy.

**Stop / reset**
```bash
# Stop and remove containers (data is kept in the volumes)
docker compose -f docker-compose.dev.yml -f docker-compose.app.yml down

# Also delete the database volumes (fresh start)
docker compose -f docker-compose.dev.yml -f docker-compose.app.yml down -v
```

---

## Local Development

### 1. Infrastructure
Ensure Docker is installed, then start the middleware stack:
```bash
docker compose -f docker-compose.dev.yml up -d
```
*Middleware includes: PostgreSQL, Neo4j, Kafka, Zookeeper, Redis, and OpenLDAP.*

### 2. Build & Run
CircleGuard uses Gradle for parallel builds across services:
```bash
# Start all microservices in parallel
./gradlew bootRun --parallel

# Start a specific service
./gradlew :services:<service-name>:bootRun
```

### 3. API Exploration
Every service exposes an OpenAPI 3.0 interface. Once running, visit:
`http://localhost:<service-port>/swagger-ui/index.html`

---

## Frontend Development

The frontend is built using **Expo (React Native)**, supporting iOS, Android, and Web from a single codebase located in `/mobile`.

### 1. Prerequisites
Ensure you have Node.js installed and dependencies loaded:
```bash
cd mobile
npm install
```

### 2. Run the Application
You can run the app in various modes depending on your target platform:

| Platform | Command | Notes |
|:---|:---|:---|
| **Development Menu** | `npm run start` | Opens the Expo Go start-up menu. |
| **Android** | `npm run android` | Requires Android Studio / Emulator or a connected device. |
| **iOS** | `npm run ios` | Requires macOS with Xcode / Simulator installed. |
| **Web Browser** | `npm run web` | Launches the dashboard/app in your default browser. |

### 3. Testing
To run frontend unit and component tests:
```bash
npm run test
```

### 4. Web App Docker Image
The web build of the app is packaged as a static site served by nginx (`mobile/Dockerfile`).

```bash
# Build (context is the mobile/ folder)
docker build -t circleguard/web:1.0.0 mobile

# Run: the app is available at http://localhost:8081
docker run -d --name circleguard-web -p 8081:8080 circleguard/web:1.0.0
```

Service URLs are supplied **at container start** through environment variables, so the same image works in every environment without rebuilding. Any variable left unset falls back to its `localhost` default.

| Variable | Default |
|:---|:---|
| `AUTH_BASE_URL` | `http://localhost:8180` |
| `IDENTITY_BASE_URL` | `http://localhost:8083` |
| `FORM_BASE_URL` | `http://localhost:8086` |
| `GATEWAY_BASE_URL` | `http://localhost:8087` |
| `PROMOTION_BASE_URL` | `http://localhost:8088` |
| `DASHBOARD_BASE_URL` | `http://localhost:8084` |
| `FILE_BASE_URL` | `http://localhost:8085` |
| `NOTIFICATION_BASE_URL` | `http://localhost:8082` |

```bash
docker run -d -p 8081:8080 \
  -e AUTH_BASE_URL=https://auth.example.com \
  -e GATEWAY_BASE_URL=https://gateway.example.com \
  circleguard/web:1.0.0
```

These URLs are called by the **browser**, so they must be reachable from the user's machine (not container-internal hostnames). The values in effect can be checked at `http://localhost:8081/env-config.js`.

---

## Testing

We maintain high system integrity via multi-level testing:

| Command | Scope |
|:---|:---|
| `./gradlew test` | Full system suite (Unit + Integration) |
| `./gradlew :services:<name>:test` | Single service testing |

**Note**: Integration tests use **Testcontainers** to spawn ephemeral Neo4j and PostgreSQL instances for zero-side-effect validation.

---

## Privacy & Compliance

- **FERPA Compliance**: Student identities are never stored in the contact graph.
- **Right to be Forgotten**: Users can trigger complete data purging via the Identity Vault.
- **Temporal Privacy**: All contact edges are automatically purged after 14 days.
