# CircleGuard — Contexto técnico

## 1. Resumen del sistema

**CircleGuard** es un sistema de *contact tracing* y "cercado sanitario" (*fencing*) para un
campus universitario. Detecta grupos de contacto interconectados —llamados **Circles**— y
propaga estados de riesgo de forma recursiva cuando alguien resulta positivo.

El objetivo declarado en `README.md` es contener brotes más rápido de lo que tarda un
resultado de laboratorio, **sin exponer la identidad real de los estudiantes**: el grafo de
contactos trabaja con IDs anónimos y la identidad real vive aislada en un "vault".

Dominio funcional real (verificado en código, no solo en el README):

- Un usuario reporta síntomas o es marcado como positivo por el Centro de Salud.
- El sistema propaga el riesgo a sus contactos en el grafo Neo4j (vecinos por aristas
  `ENCOUNTERED` y por pertenencia a círculos `MEMBER_OF`), dentro de una ventana temporal.
- Los estados hacen *cascade*: `CONFIRMED` → vecinos `SUSPECT` → vecinos `PROBABLE`, y un
  segundo salto a `PROBABLE` si el origen es `CONFIRMED` (`HealthStatusService.updateStatus`).
- Se notifican los afectados por múltiples canales, se liberan automáticamente al vencer la
  ventana obligatoria de aislamiento, y la entrada al campus se valida por QR con el estado
  en caché Redis.

---

## 2. Arquitectura

Monorepo **Gradle multi-módulo** (Kotlin DSL) + app móvil. Estilo **microservicios** con un
modelo de datos **híbrido** (grafo + relacional) y comunicación **asíncrona por Kafka**.

```
                                  ┌──────────────────────────────┐
   Móvil/Web (Expo, React Native) │      mobile/  (TypeScript)    │
                                  └───────────────┬──────────────┘
                                                  │ HTTP (axios/fetch)
        ┌──────────────┬──────────────┬───────────┼───────────┬─────────────┬────────────┐
        ▼              ▼              ▼           ▼           ▼             ▼            ▼
  auth(8180)    identity(8083)  promotion   gateway(8087)  form(8086)  dashboard  notification
                                    (8088)                  file(8085)   (8084)      (8082)
        │              │              │           │           │             │            │
   PostgreSQL ◄──── PostgreSQL ◄── Neo4j+PG+Redis │      PostgreSQL      PostgreSQL   (sin BD)
   LDAP (OpenLDAP)   (vault)          │           │        + /tmp
                                      ▼           ▼
                                   Apache Kafka (event bus)
```

Hechos arquitectónicos verificados:

- **No hay API Gateway de infraestructura ni orquestador de rutas.** El nombre
  "gateway-service" es engañoso: `circleguard-gateway-service` es únicamente el servicio de
  **validación de acceso en portería** vía QR (`GateController`, `QrValidationService`).
  Cada consumidor llama directamente a cada servicio por su URL/puerto
  (`mobile/constants/Config.ts`).
- **No hay descubrimiento de servicios (Nacos/Eureka/Consul)** ni config central (Vault).
  Las URLs están hardcodeadas o en properties por servicio.
- **No hay un único origen de verdad de eventos Kafka.** Cada servicio declara sus topics
  como *strings literales*; no hay schema registry ni contratos compartidos.
- **Las librerías compartidas no existen.** `settings.gradle.kts:14-17` comenta
  `libs:circleguard-common`, `libs:circleguard-security`, `libs:circleguard-events` con la
  nota "folders are missing on disk". Hay **duplicación real** derivada de esto: el
  `JwtAuthenticationFilter` está copiado en `promotion` (paquete `security/`) e `identity`
  (paquete `config/`), y el filtro/secret JWT se repiten en `auth`.
- **No se usa Kubernetes.** El despliegue es Docker Compose sobre instancias EC2; las
  imágenes se publican en Nexus y se despliegan con `deploy/docker-compose.yml` (ver
  [`docs/operaciones/despliegue.md`](../operaciones/despliegue.md)). La infraestructura de
  CI/CD (Jenkins, Nexus, SonarQube) se aprovisiona con scripts Bash y Docker Compose en
  `infra/bootstrap/`.

---

## 4. Estructura de módulos

### 4.1 Backend — `services/` (8 microservicios, todos Java/Spring Boot)

| Módulo | Puerto | Responsabilidad | Persistencia |
|---|---|---|---|
| `circleguard-auth-service` | **8180** | Login dual LDAP/local, emisión JWT, QR token, usuarios/roles/permisos | PostgreSQL `circleguard_auth` |
| `circleguard-identity-service` | **8083** | Vault de identidades: anonimización + resolución real | PostgreSQL `circleguard_identity` |
| `circleguard-promotion-service` | **8088** | **Núcleo**: grafo de contactos, propagación de estado, círculos, topología espacial | **Neo4j + PostgreSQL + Redis + Kafka** |
| `circleguard-notification-service` | **8082** | Despacho multi-canal (email/SMS/push) y listeners Kafka | **Sin BD** (stateless) |
| `circleguard-form-service` | **8086** | Cuestionarios dinámicos, encuestas de salud, validación de certificados | PostgreSQL `circleguard_form` |
| `circleguard-gateway-service` | **8087** | Validación de QR de acceso en portería | **Redis** (lee estado) |
| `circleguard-dashboard-service` | **8084** | Analítica de campus con filtro **k-anonimato** | PostgreSQL `circleguard_dashboard` |
| `circleguard-file-service` | **8085** | Subida de archivos (multipart) | Disco local (`uploads/`) |

### 4.2 `circleguard-promotion-service` — el núcleo 

Ubicación: `services/circleguard-promotion-service/src/main/java/com/circleguard/promotion/`

- **`model/graph/`** — Neo4j: `UserNode` (etiqueta `User`, id `anonymousId`, `status`),
  `CircleNode` (etiqueta `Circle`, `inviteCode`, `isAutoGenerated`), `EncounterRelationship`
  (arista `ENCOUNTERED` con `startTime`, `duration`, `locationId`, `isValid`, `forceFence`).
- **`model/jpa/` + `model/`** — PostgreSQL: `SystemSettings` (singleton de umbrales),
  `Building`, `Floor`, `AccessPoint` (topología WiFi del campus para geolocalización).
- **`repository/graph/`** — `UserNodeRepository` (Cypher: `recordEncounter`,
  `purgeStaleEncounters`, conteos de conexiones), `CircleNodeRepository` (`joinCircle`,
  `findNewlyFencedCircles`).
- **`repository/jpa/`** — repositorios JPA de topología y settings.
- **`service/`** — ver §5 (flujos).
- **`controller/`** — REST (ver tabla de endpoints §5).
- **`security/`** — `SecurityConfig`, `JwtAuthenticationFilter`.
- **`config/`** — `Neo4jConfig` (`neo4jTransactionManager`), `JpaConfig` (`transactionManager`
  `@Primary`), `DataLayerConfig` (habilita ambos repos), `CacheConfig` (Caffeine),
  `Neo4jSchemaConfig` (índices `@PostConstruct`).
- **`task/GraphCleanupTask`** — purga temporal de aristas.
- **`listener/SurveyListener`** — consume encuestas del form-service.

### 4.3 App móvil — `mobile/`

- **`app/`** — rutas expo-router (§5.2).
- **`context/AuthContext.tsx`** — estado de sesión (token + anonymousId).
- **`hooks/`** — encapsulan llamadas HTTP: `useQrToken`, `useCircles`, `useMeshStats`,
  `useSpatial`, `useGateValidation`, `usePermission`, `useBiometricAuth`, `useAuth` (legacy).
- **`constants/Config.ts`** — las 8 URLs base (todas `localhost`).
- **`utils/`** — `storage.ts` (SecureStore/localStorage), `proximityScanner.ts` y
  `proximityTask.ts` (escaneo en background).
- **`components/`** — `DynamicForm`, `QuestionInput`, `MeshBackground`, `ScanResultOverlay`.

### 4.4 Otros directorios

- **`docs/`** — documentación del proyecto (arquitectura, operaciones, proceso ágil) y assets de diseño.
- **`design-assets/`**, **`scratch/`** — artefactos de diseño/trabajo, no forman parte del sistema en runtime.
- **`Proyecto_Final_CircleGuard.{pdf,tex}`** — documento LaTeX/PDF del proyecto (material académico).
- **`.github/`** — workflows de `commitlint` y versionado semántico, además de la plantilla de PR.
- **`.agent/workflows/run-project.md`** — workflow de agente; no afecta al runtime.

---

## 5. Flujos principales

### 5.1 Flujo de propagación de estado (el corazón del sistema)

Punto de entrada: `HealthStatusService.updateStatus(anonymousId, status, adminOverride)`
(en `promotion/.../service/HealthStatusService.java`, ~305 líneas).

1. **Protección de ventana** (`checkFenceWindow`, L285-304): si se intenta volver a
   `ACTIVE` sin `adminOverride` y `statusUpdatedAt` es más reciente que
   `mandatoryFenceDays`, lanza `FenceException` → HTTP 403.
2. Lee `SystemSettings` (fallback con `encounterWindowDays = 14`).
3. **Query Cypher multi-hop** (L58-88): dentro de la ventana temporal
   (`startTime > now - encounterWindowDays`),
   - vecinos por `ENCOUNTERED` (con `isValid`) o por `MEMBER_OF` (círculos `isValid`);
   - `CONFIRMED` → vecino pasa a `SUSPECT`; `SUSPECT` → vecino pasa a `PROBABLE`;
   - segundo salto **solo si el origen es `CONFIRMED`**: vecinos `ACTIVE` de Nivel 1 → `PROBABLE`;
   - excluye a quienes ya son `CONFIRMED`/`RECOVERED`.
4. Sincroniza **Redis** (`user:status:<id>`, `multiSet` en lotes de 2000).
5. Publica en Kafka `promotion.status.changed` por usuario.
6. `checkAndBroadcastFencedCircles` → por cada círculo totalmente cercado publica `circle.fenced`.
7. Si el origen es `CONFIRMED` o `affectedCount > 20` → publica alerta en `alert.priority`.

Estados reales en uso: `ACTIVE`, `SUSPECT`, `PROBABLE`, `CONFIRMED`, `RECOVERED`.
(El comentario de `UserNode.java:20` menciona "CONTAGIED/RECOVERED"; **no coincide** con el código.)

**Liberación ("Pulse Recovery")**: `resolveStatus(anonymousId, adminOverride)` libera en 2
fases a los contactos que ya no tienen camino a un `CONFIRMED`. `promoteToRecovered` mueve a
`RECOVERED` (Redis con TTL 30 días).

**Liberación automática**: `StatusLifecycleService.processAutomaticTransitions()`
(`@Scheduled(cron = "0 0 * * * *")`, cada hora) devuelve a `ACTIVE` los `SUSPECT`/`PROBABLE`
con `statusUpdatedAt < now - mandatoryFenceDays`, con `reason: AUTO_WINDOW_EXPIRY`.

### 5.2 Flujo de encuentros vía WiFi (topología del campus)

`LocationResolutionService.processSignal(apMac, deviceMac, rssi)` ← `POST /api/v1/location/signal`:

1. Resuelve el `AccessPoint` por MAC en PostgreSQL.
2. Resuelve el usuario: `MacSessionRegistry` (Redis `session:mac:<mac>`, **TTL 8 h**). Si no
   hay sesión activa, ignora la señal (MAC randomizada).
3. Publica `proximity.detected` en Kafka.
4. `updateGraph`: lee el set Redis `spatial:location:<apId>` (presencia, **TTL 10 min**), registra
   `recordEncounter` con cada otro presente y se auto-agrega al set.
5. `GraphService.detectAndFormCircles(locationId)`: si hay ≥3 usuarios en la misma ubicación
   con `duration > 300` s, crea un **Auto-Circle** (`isAutoGenerated = true`).

`GraphCleanupTask.purgeStaleEncounters()` (cada hora) borra aristas con
`startTime < now - 14 días` (TTL hardcodeado).

### 5.3 Flujo de encuesta de salud → promoción

1. Móvil: `app/questionnaire.tsx` carga `GET /api/v1/questionnaires/active`, renderiza
   `DynamicForm`, adjunta certificado opcional (`POST /api/v1/attachments`) y envía
   `POST /api/v1/surveys`.
2. `form/HealthSurveyService.submitSurvey` → `SymptomMapper.hasSymptoms` → guarda → publica
   `survey.submitted` `{anonymousId, hasSymptoms, timestamp}`.
3. `promotion/SurveyListener` consume: si `hasSymptoms == true` → `updateStatus(id, "SUSPECT")`.
4. Validación de certificado: `POST /api/v1/certificates/{id}/validate?status=APPROVED` →
   publica `certificate.validated` → `SurveyListener` → `updateStatus(id, "ACTIVE")`.

### 5.4 Flujo de login y QR de portería

1. `POST /api/v1/auth/login` (móvil `app/login.tsx`) →
   `DualChainAuthenticationProvider`: intenta **LDAP** (`uid={0},ou=people`); si falla,
   **fallback local** BCrypt (`local_users`). Devuelve `{token, anonymousId}`.
2. El JWT tiene `subject = anonymousId` y claim `permissions` (lista de autoridades).
3. Pantalla de inicio genera QR rotativo: `GET /api/v1/auth/qr/generate`
   (`useQrToken`, rota cada 60 s).
4. Portería: `app/(tabs)/scan.tsx` escanea con `CameraView` (tras bloqueo biométrico) →
   `POST /api/v1/gate/validate` → `QrValidationService`: valida firma HS256 con `qr.secret`,
   consulta Redis `user:status:<id>`, devuelve `GREEN`/`RED`.

### 5.5 Flujo de visitantes

`app/visitor.tsx` → `POST /api/v1/identities/visitor` (crea identidad compuesta
`VISITOR|email|name|reason`) → `POST /api/v1/auth/visitor/handoff` → QR con payload
`HANDOFF_TOKEN:<uuid>:<token>`. En `app/enroll.tsx` se escanea ese pase para enrolarse.

### 5.6 Mapa de eventos Kafka

| Topic | Producer | Consumer(s) |
|---|---|---|
| `promotion.status.changed` | promotion (`HealthStatusService`, `StatusLifecycleService`) | notification (`ExposureNotificationListener`) |
| `circle.fenced` | promotion (`HealthStatusService:150`) | notification (`CircleFencedListener`) |
| `alert.priority` | promotion (`HealthStatusService:135`) | notification (`PriorityAlertListener`) |
| `proximity.detected` | promotion (`LocationResolutionService`) | **ninguno en el repo** |
| `survey.submitted` | form (`HealthSurveyService`) | promotion (`SurveyListener`) |
| `certificate.validated` | form (`HealthSurveyService`, solo `APPROVED`) | promotion (`SurveyListener`) |
| `audit.identity.accessed` | identity (`IdentityVaultController:97`) | **ninguno** |
| `notification.audit` | notification (`AuditLogService`) | **ninguno** |

`auth`, `gateway`, `dashboard` y `file` **no usan Kafka**.

---

## 6. Persistencia

### 6.1 Bases de datos PostgreSQL (5, creadas por `init-db.sql`)

| Base | Servicio | Tablas (migraciones Flyway) |
|---|---|---|
| `circleguard_auth` | auth | `permissions`, `roles`, `role_permissions`, `local_users`, `user_roles` (V1-V5) |
| `circleguard_identity` | identity | `identity_mappings` (`anonymous_id` PK, `real_identity_encrypted BYTEA`, `identity_hash` UNIQUE, `salt`) |
| `circleguard_promotion` | promotion | `system_settings`, `buildings`, `floors`, `access_points` (V1-V3) |
| `circleguard_dashboard` | dashboard | `entry_logs` (V1)  **sin entidad JPA ni escritor** |
| `circleguard_form` | form | `health_surveys`, `questionnaires`, `questions` (V1-V5, con `JSONB`) |

 `gateway` y `notification` no tienen esquema propio.

**Inconsistencia de migración**: los `application.yml` de `auth`, `identity` y `promotion`
declaran `jpa.hibernate.ddl-auto: update` **a pesar de usar Flyway**. Puede regenerar/esquema
en conflicto. `form` y `dashboard` también usan `update`.

### 6.2 Neo4j (solo `promotion`)

- Nodos `User` (`anonymousId`, `status`, `statusUpdatedAt`) y `Circle` (`inviteCode`,
  `isAutoGenerated`, `isValid`, `forceFence`).
- Relaciones: `ENCOUNTERED` (arista con temporalidad) y `MEMBER_OF`.
- Índices en `Neo4jSchemaConfig`: `user_anon_id_idx`, `user_status_idx`, `encounter_time_idx`
  (sobre `r.startTime`), `circle_invite_idx`, `circle_loc_idx`.

### 6.3 Redis

| Clave | TTL | Servicio | Uso |
|---|---|---|---|
| `user:status:<anonymousId>` | — | promotion (escritura) / gateway (lectura) | Estado de salud para validación rápida de portería |
| `session:mac:<mac>` | 8 h | promotion | Mapeo MAC randomizada → anonymousId |
| `spatial:location:<apId>` | 10 min | promotion | Set de presencia por punto de acceso WiFi |

### 6.4 Almacenamiento de archivos

- `form/StorageService`: disco local `/tmp/circleguard-uploads`.
- `file/FileStorageService`: disco relativo `uploads/` (CWD).  `loadFile()` es un stub que
  `return null` y declara una `interface Resource {}` local que **sombrea** `org.springframework.core.io.Resource`.
- S3/MinIO: **pendiente** (bloque comentado en `file-service/application.yml`).

---

## 7. Seguridad

### 7.1 Identidad y anonimato (implementado y verificado)

- **Vault** (`identity`): la identidad real se guarda **cifrada** con
  `IdentityEncryptionConverter` → Spring `Encryptors.text(vault.secret, vault.salt)` (AES,
  clave derivada), en columna `BYTEA`.
- **Blind index** (`IdentityVaultService.computeHash`): `SHA-256(input + hashSalt)` con
  `hash-salt` **global** (`vault.hash-salt`).
  Existe una columna `salt` por usuario que **se genera y persiste pero nunca se usa** en
  el cálculo del hash. No es "hash con sal por usuario" pese a lo que sugiere el esquema.
- El grafo Neo4j **solo contiene `anonymousId`**; nunca identidad real. Consistente con el
  objetivo de privacidad del README.

### 7.2 Autenticación

- **Dual-chain** (`auth/security/DualChainAuthenticationProvider`): LDAP primero, fallback
  local BCrypt. `CustomUserDetailsService` expone `ROLE_<name>` + permisos planos.
- **JWT HS256** (`JwtTokenService`): `subject = anonymousId`, claim `permissions`. Expiración
  1 h. El mismo `jwt.secret` se repite en `auth`, `promotion`, `identity`, `gateway`.
- El móvil decodifica el JWT a mano sin validar firma ni expiración
  (`mobile/hooks/usePermission.ts`).

### 7.3 Autorización

- Modelo RBAC relacional completo en `auth` (roles `HEALTH_CENTER`, `GATE_STAFF`, `STUDENT`;
  permisos `gate:scan`, `identity:lookup`, `circle:checkin`, `symptom:report`,
  `alert:receive_priority`, `dashboard:view`; usuarios seed `staff_guard`, `health_user`,
  `super_admin` con password `password`).
- Enforcement **desigual** entre servicios (ver §10): `promotion` e `identity` usan
  `@EnableMethodSecurity` + `@PreAuthorize`; `auth`, `form`, `dashboard`, `gateway`, `file`
  no aplican autorización efectiva.

### 7.4 Privacidad analítica

- `dashboard/KAnonymityFilter` (k=5 por defecto): enmascara campos `*Count` y `totalUsers`
  cuando el conteo es menor a k ("Insufficient data for privacy").
- ⚠️ La máscara k<5 está **duplicada en línea** en `AnalyticsService.getEntryTrends` y
  `getGlobalHealthStats` **no aplica** el filtro (solo el endpoint de departamento lo usa).

---

## 8. Configuración y ejecución

> Los comandos de esta sección son para desarrollo local. El despliegue en AWS, las imágenes
> y la promoción entre entornos se documentan en
> [`docs/operaciones/despliegue.md`](../operaciones/despliegue.md).

### 8.1 Infraestructura de desarrollo

```bash
docker-compose -f docker-compose.dev.yml up -d
```

Levanta: PostgreSQL 16 (`admin`/`password`, init con `init-db.sql`), Neo4j 5.26
(`neo4j`/`password`, puerto 7474/7687, plugin APOC), Zookeeper + Kafka 7.6 (`localhost:9092`),
Redis 7.2 (`localhost:6379`), OpenLDAP (`circleguard.edu`, admin/`admin`, puerto 389/636).

### 8.2 Backend

```bash
./gradlew bootRun --parallel                       # todos
./gradlew :services:circleguard-promotion-service:bootRun   # uno
./gradlew test                                     # suite completa
```

El README menciona `--parallel`; verificar que Gradle lo soporte en este contexto de
subproyectos (configuración por defecto). Puertos: ver tabla §4.1.

### 8.3 Móvil

```bash
cd mobile && npm install
npm run start    # Expo Go
npm run android | npm run ios | npm run web
npm test         # jest-expo
```

### 8.4 Variables de configuración

No hay `.env` ni variables `EXPO_PUBLIC_*`. Todo está hardcodeado en `application.yml` de
cada servicio y en `mobile/constants/Config.ts` (URLs `localhost`). Secretos de desarrollo
(`jwt.secret`, `qr.secret`, `vault.secret`) están **en texto plano en el repo** — apropiado
solo para desarrollo local.

---

## 9. Pruebas

### 9.1 Backend

> Estado al momento del análisis. La evidencia actual de pruebas y cobertura está en
> [`docs/operaciones/pruebas.md`](../operaciones/pruebas.md).

Estado en el momento del análisis (tras los arreglos de §12): **52 tests, 0 fallos, 0 errores**
en los 8 servicios.
`./gradlew test` → `BUILD SUCCESSFUL`.

Distribución: `promotion` 20 · `notification` 11 · `identity` 8 · `form` 6 · `gateway` 3 ·
`dashboard` 2 · `auth` 1 · `file` 1.

`promotion` es la única suite con **Testcontainers** (Neo4j y PostgreSQL efímeros):
`HealthStatusReevaluationTest`, `HealthStatusServiceTest`, `StatusLifecycleTest`,
`AdministrativeCorrectionTest`, `SurveyListenerTest`, `HealthStatusControllerTest`,
`FloorServiceTest`, `PromotionPerformanceTest` (benchmark con 10k nodos).

Los demás servicios tienen tests unitarios/MockMvc (`QrValidationServiceTest`,
`IdentityEncryptionConverterTest`, `NotificationRetryTest`, `QuestionnaireControllerTest`,
`AnalyticsControllerTest`, `LoginControllerTest`, entre otros). H2 en memoria para tests.

⚠️ `NotificationRetryTest` usa `@ActiveProfiles("test")` y **no hay
`src/test/resources/application.yml` en ese servicio** → cae al config principal.

### 9.2 Móvil

Solo 2 archivos: `hooks/useQrToken.test.ts` (4 tests) y
`components/__tests__/DynamicForm.test.tsx`.
⚠️ **La suite móvil no ejecuta** en el estado actual: `mobile/test-output.txt` muestra un
error Babel (`react-native/jest/react-native-env.js: .plugins is not a valid Plugin property`).
Además `useQrToken.test.ts` está desalineado con la firma actual del hook
(`useQrToken(anonymousId, authToken)`).

### 9.3 CI/CD

El proyecto usa Jenkins (job multibranch `circleguard`) y la librería compartida
`circleguard-pipeline-library`. El pipeline construye, ejecuta pruebas unitarias, de
integración y E2E, analiza con SonarQube, publica imágenes en Nexus y despliega en AWS.
GitHub Actions ejecuta `commitlint` y semantic-release. Ver
[`docs/operaciones/pipeline.md`](../operaciones/pipeline.md) y
[`docs/operaciones/versionado.md`](../operaciones/versionado.md).

---

## 10. Riesgos, inconsistencias y aspectos desconocidos

### 10.1 Inconsistencias históricas del README (ya corregidas)

El README original afirmaba Spring Boot 4, Kubernetes, OpenAPI/Swagger en todos los servicios
y S3 para `file-service`. El README actual y este documento reflejan la realidad del código:
Spring Boot 3.2.4, Docker Compose sobre EC2, sin Swagger y con almacenamiento local. Se
conservan los riesgos de las secciones siguientes porque siguen vigentes.

### 10.2 Riesgos de seguridad y robustez (verificados en código)

1. **Autorización parcial.** `auth`, `form`, `dashboard`, `gateway` y `file` no aplican
   `@EnableMethodSecurity` ni `@PreAuthorize` efectivos. En `auth`, `SecurityConfig` termina
   en `anyRequest().permitAll()`; en `UserController` el `@PreAuthorize` está importado pero
   **sin usar**. En `form`, `validateSurvey` acepta `adminId` como request param **sin verificarlo**.
   En `promotion`, `SecurityConfig` solo protege `/api/v1/health/**` con `authenticated()`;
   endpoints de admin, circles, sessions y location quedan `permitAll` (aunque algunos tienen
   `@PreAuthorize` a nivel de método).
2. **`gateway` no tiene `SecurityConfig` ni filtro JWT**: `POST /api/v1/gate/validate` está
   abierto, sin anti-replay ni consumo del token.
3. **Bug de expiración del QR** (verificado):
   `QrTokenService` usa `@Value("${qr.expiration:60000}")` y aplica
   `System.currentTimeMillis() + expiration`. El `application.yml` define `qr.expiration: 300`
   → el QR caduca en **0.3 segundos**, no en 60 s como reporta el endpoint
   (`expiresIn: "60"`). Contradicción directa.
4. **Serialización Kafka frágil.** Solo `form-service` configura
   `value-serializer: JsonSerializer`. `identity` y `notification` publican POJOs sin
   configurarlo → riesgo de `ClassCastException` en runtime.
5. **Secretos en claro** en el repo (`jwt.secret`, `qr.secret`, `vault.secret`, credenciales
   de DB/LDAP en `docker-compose.dev.yml` y `application.yml`).
6. **Consumidores Kafka huérfanos**: `proximity.detected`, `audit.identity.accessed` y
   `notification.audit` **no tienen ningún consumidor** en el monorepo.

### 10.3 Bugs funcionales en el móvil (verificados)

1. **`useGateValidation.ts` importa `API_BASE_URL`** (líneas 2 y 31), constante que **no
   existe** en `constants/Config.ts` (que exporta `GATEWAY_BASE_URL`). En runtime la URL
   queda `undefined/api/v1/gate/validate` → **la pantalla de escaneo de portería no puede
   validar tokens**.
2. **Doble instancia de auth.** `context/AuthContext.tsx` (usado por las pantallas) y
   `hooks/useAuth.ts` (usado por `usePermission` y `useGateValidation`) mantienen **estados
   separados** sobre las mismas claves de SecureStore → el logout no se propaga de forma
   inmediata entre los dos árboles.
3. **`utils/proximityTask.ts:19`** lee `SecureStore.getItemAsync('user_anonymous_id')`, pero
   la app guarda el id como `circleguard_anon_id`. Además en web `SecureStore` está vacío →
   **la sincronización BLE en background nunca reporta datos reales**.
4. **Conflictos de ruta `/admin`.** `app/admin/index.tsx` y `app/(tabs)/admin/index.tsx` ambos
   mapean a `/admin`. Solo el de `(tabs)` tiene guard de permisos (`dashboard:view`); el otro
   no. Enlaces `Link href="/admin"` apuntan a esa ruta ambigua.
5. **`app/(tabs)/scan.tsx`** usa `<MeshBackground />` **sin props** en 3 sitios, pese a que
   las props son requeridas → error con `tsconfig` en modo `strict`.
6. **`MeshBackground.tsx`** usa `useAnimatedProps` dentro de un `.map` (línea 152), patrón
   que viola las reglas de hooks.

### 10.4 Código muerto / stubs identificados

- `promotion/SpatialService` duplica `BuildingService`/`FloorService`/`AccessPointService` y
  **no está inyectado** en ningún controller.
- `SystemSettings.unconfirmedFencingEnabled` y `autoThresholdSeconds` se persisten/togglean
  pero **no se leen** en la propagación (el umbral de auto-círculos está hardcodeado como
  `AUTO_THRESHOLD_SECONDS = 3600` en `AutoCircleService`).
- `forceFence` (en `CircleNode` y `EncounterRelationship`) se **escribe** pero **nunca se
  lee** en las queries de propagación (solo se chequea `isValid`).
- `HealthStatusService.getCachedStatus` / `evictUserCache` sin llamadores; caches Caffeine
  `proximityMatches` y `buildingMetadata` declaradas pero sin uso.
- `notification/LmsServiceImpl` y `RoomReservationServiceImpl` son **mocks** que solo loguean
  (WebClient comentado). `identity.api.url` apunta a puerto **8081** (identity es 8083).
- `notification/PriorityAlertListener` genera el contenido del email pero **no lo envía**
  (comentario: "mock the dispatch for now").
- `file/FileStorageService.loadFile` devuelve `null` (stub); no hay endpoint de descarga.
- `dashboard`: `entry_logs` sin entidad/escritor; `getTimeSeries` consulta una tabla
  `status_events` **inexistente** → siempre devuelve mock con `Random(42)`.
- `User.department` existe solo en datos seed (`seed_faculties.cypher`) →
  `GET /health-status/stats/department/{d}` devuelve zeros con datos reales.
- `LocationResolutionService`: los usuarios **nunca se eliminan individualmente** del set
  `spatial:location:<apId>` (no hay `SREM`), solo expira la clave completa.
- Mobile: `enroll.tsx` "frictionless" es en la práctica un redirect a `login`;
  `ProximityScanner` es un mock; la gráfica de 7 días del dashboard es placeholder
  ("Requires D3/Recharts"); subida de planos solo en web.

### 10.5 Aspectos desconocidos / no verificables en el repo

- **¿Cómo se coordinan los esquemas entre servicios?** No hay schema registry de Kafka ni
  contratos compartidos; los payloads son `Map`/POJOs ad hoc. La coordinación es implícita.
- **Estrategia de despliegue real**: no existe en el repo (ver §8). El README menciona k8s
  pero no hay artefactos. Desconocido.
- **`scratch/` y `.github/`**: no contienen código en runtime; el propósito exacto de
  `scratch/` no se determinó más allá de artefactos de trabajo.
- **Datos seed reales del campus**: existe `seed_faculties.cypher` (referenciado en
  `User.department`), pero no se verificó su origen ni si corresponde a datos de prueba.
- **`Proyecto_Final_CircleGuard.pdf/tex`**: material académico; no se revisó su contenido
  (documento largo). Puede contener requisitos que no estén reflejados en el código.
- **Notas de versión sobre por qué `Spring Boot` es 3.2.4 y no 4** (prometido en README):
  desconocido; pudo ser limitación de compatibilidad o un cambio tardío de alcance.

---

## 11. Puntos de entrada para un nuevo desarrollador

Si vas a trabajar aquí, estos son los archivos que conviene abrir primero:

1. `services/circleguard-promotion-service/.../service/HealthStatusService.java` — el
   algoritmo de propagación (todo lo demás gira alrededor de esto).
2. `services/circleguard-promotion-service/.../repository/graph/UserNodeRepository.java` —
   las consultas Cypher de encuentros.
3. `services/circleguard-promotion-service/src/main/resources/application.yml` — configuración
   del núcleo (Neo4j/Redis/Kafka/JPA).
4. `mobile/context/AuthContext.tsx` + `mobile/constants/Config.ts` — sesión y URLs de la app.
5. `services/circleguard-auth-service/.../security/DualChainAuthenticationProvider.java` —
   cómo se autentica.
6. `docker-compose.dev.yml` — toda la infraestructura local.

**Antes de tocar el móvil**, revisa §10.3: hay bugs verificados que afectan funcionalidad
central (validación de portería, auth duplicada, sync BLE) que probablemente quieras
corregir o tener presentes.

---

## 12. Bugs arreglados (changelog)

Registro de lo que **no funcionaba**, por qué, y cómo se solucionó. Todo verificado
empíricamente: se reprodujo el fallo, se aplicó el arreglo, y se comprobó que pasaba.

> Este changelog es histórico. La evidencia actual de pruebas y cobertura está en
> [`docs/operaciones/pruebas.md`](../operaciones/pruebas.md).

### 12.0 Cómo ejecutar el proyecto (lo que hay que saber)

```bash
# Gradle 8.14 NO soporta Java 25. Usar JDK 21 explícitamente:
export JAVA_HOME=/usr/lib/jvm/java-21-openjdk-amd64

docker compose -f docker-compose.dev.yml up -d   # infraestructura
./gradlew test                                    # 52 tests, 0 fallos
./gradlew :services:circleguard-promotion-service:bootRun   # un servicio
```
---

### 12.1 Bug en producción — colisión de caché que rompía el endpoint central

| | |
|---|---|
| **Síntoma** | `POST /api/v1/health/confirmed` → **500** (`ClassCastException`) |
| **Archivo** | `promotion/.../controller/AdminController.java` |
| **Gravedad** | Alta: rompe el flujo principal del sistema |

`AdminController.getSettings()` y `SystemSettingsRepository.getSettings()` usaban **el mismo
nombre de caché (`systemSettings`) y la misma clave por defecto** (ninguna, es decir
`SimpleKey.EMPTY`), pero con **tipos de retorno incompatibles**:

```java
// AdminController.java          → @Cacheable("systemSettings") devuelve ResponseEntity<SystemSettings>
// SystemSettingsRepository.java → @Cacheable("systemSettings") devuelve Optional<SystemSettings>
```

Al llamar `GET /api/v1/admin/settings` se guardaba un `ResponseEntity` en esa entrada. La
siguiente vez que `HealthStatusService.updateStatus()` llamaba `getSettings()` recibía ese
`ResponseEntity` donde esperaba un `Optional` → `ClassCastException` en tiempo de
ejecución. El error ocurría en **ambos sentidos** (`ResponseEntity → SystemSettings` y
`SystemSettings → ResponseEntity`), según qué llamada envenenara primero.

**Solución:** eliminar el `@Cacheable` del controller. Era redundante: el repositorio ya
cachea ese dato, que es donde está realmente el acceso a BD. Cachearlo dos veces en dos
capas no aporta nada y era la causa del conflicto. Se dejó un comentario en el código
explicando por qué no debe volver.

---

### 12.2 Bug en producción — Kafka no podía serializar los eventos

| | |
|---|---|
| **Síntoma** | `POST /api/v1/health/confirmed` → **500** tras arreglar 12.1 |
| **Archivos** | `promotion`, `identity`, `notification` → `application.yml` |
| **Gravedad** | Alta: los eventos nunca llegaban a Kafka |

`kafkaTemplate.send(...)` publicaba objetos `Map`/POJO, pero **solo estaba configurado el
*consumer***. El *producer* usaba el default de Spring (`StringSerializer`), que exige un
`String`:

```
java.lang.ClassCastException: class java.util.HashMap cannot be cast to class java.lang.String
```

**Solución:** declarar el producer en los 3 `application.yml`:

```yaml
spring:
  kafka:
    producer:
      key-serializer: org.apache.kafka.common.serialization.StringSerializer
      value-serializer: org.springframework.kafka.support.serializer.JsonSerializer
```

`form-service` ya lo tenía bien; los otros tres no. **Verificación final:**
`promotion.status.changed`, `alert.priority`, `circle.fenced` y `audit.identity.accessed`
publican correctamente, y `notification-service` consume los eventos.

---

### 12.3 Bug de tests — Testcontainers incompatible con Docker moderno

| | |
|---|---|
| **Síntoma** | 3 tests con `initializationError` |
| **Archivo** | `promotion/build.gradle.kts` |
| **Tests** | `PromotionPerformanceTest`, `AdministrativeCorrectionTest`, `HealthStatusReevaluationTest` |

```
IllegalStateException: Could not find a valid Docker environment
Caused by: BadRequestException (Status 400: {"message":"client version 1.32 is too old. 
Minimum supported API version is 1.40, please upgrade your client"})
```

**¿Qué es esto?** Testcontainers son librerías Java que **crean bases de datos dentro de
contenedores Docker descartables** para los tests de integración: levantan un Neo4j y un
PostgreSQL efímeros, corren el test y los borran. Así los tests no dependen de que tú
tengas las bases montadas.

El problema: esas librerías hablan con Docker por su **API** (una interfaz de
comunicación), y **cada versión de Docker soporta un rango de versiones de esa API**. La
versión del proyecto, Testcontainers **1.19.3**, traía la librería `docker-java 3.3.6`, que
habla **API versión 1.32**. Pero el Docker instalado en esta máquina es el **29.9.2**, que
ya **no acepta nada por debajo de la API 1.40**. Resultado: el rechazo con `400`.

Es decir: **no es que Docker estuviera mal configurado, ni que faltaran permisos** (se
comprobó que el socket funcionaba). Es puramente una **versión de librería desactualizada**.

**Solución (con un matiz importante):** basta con subir la versión de Testcontainers a
**1.21.4**, que ya trae `docker-java 3.4.2` (API compatible). Pero **no bastó con solo
cambiar las tres líneas de dependencias**, porque el **BOM de Spring Boot 3.2.4** gestiona
Testcontainers a `1.19.7` y lo volvía a forzar en la resolución. Hizo falta un bloque
`dependencyManagement`, que tiene prioridad sobre el BOM importado:

```kotlin
dependencyManagement {
    imports { mavenBom("org.testcontainers:testcontainers-bom:1.21.4") }
    dependencies {
        dependency("org.testcontainers:testcontainers:1.21.4")
        // ... junit-jupiter, postgresql, neo4j
    }
}
```

Comprobación: `./gradlew :services:circleguard-promotion-service:dependencies --configuration testRuntimeClasspath`
→ ahora resuelve `testcontainers:1.21.4` con `docker-java-api:3.4.2`.

> **Regla práctica para el futuro:** si al actualizar Docker ves este error en los tests,
> es que la versión de Testcontainers quedó vieja. Subir Testcontainers lo resuelve.

---

### 12.4 Bug de tests — authorities mal declaradas en MockMvc

| | |
|---|---|
| **Síntoma** | `expected:<200> but was:<403>` |
| **Archivo** | `promotion/.../controller/HealthStatusControllerTest.java` |
| **Tests** | `resolve_WithPermission_CallsResolveStatus`, `confirmPositive_WithPermission_CallsUpdateStatus` |

Spring Security hace una **distinción importante** que suele confundir:

- `hasRole('HEALTH_CENTER')` busca la autoridad **`ROLE_HEALTH_CENTER`** (con el prefijo
  `ROLE_`, que Spring añade por convención).
- `@WithMockUser(authorities = "HEALTH_CENTER")` crea la autoridad **`HEALTH_CENTER`**
  (exactamente ese texto, **sin** el prefijo).

No coinciden → 403. La anotación correcta en el test es:

```java
@WithMockUser(roles = "HEALTH_CENTER")   // roles añade "ROLE_" automáticamente ✅
```

**El código de producción estaba bien**, lo confirmé en vivo: el JWT real emitido para
`health_user` incluye `ROLE_HEALTH_CENTER` en el claim `permissions`, y el endpoint
`/api/v1/health/confirmed` responde **200**. El error estaba únicamente en el test.

---

### 12.5 Bug de tests — `jwt.secret` sin resolver en identity

| | |
|---|---|
| **Síntoma** | 4 tests con fallo al crear el `ApplicationContext` |
| **Archivo** | `identity/src/test/resources/application.yml` |
| **Test** | `IdentityVaultControllerTest` (4 tests) |

```
io.jsonwebtoken.security.WeakKeyException: The specified key byte array is 104 bits 
which is not secure enough for any JWT HMAC-SHA algorithm
```

En una suite Maven/Gradle, el `application.yml` de `src/test/resources/` **reemplaza** al de
`src/main/resources/` (no se fusionan). El de test de identity **no declaraba
`jwt.secret`**, así que `JwtAuthenticationFilter` recibía el placeholder **sin resolver**
como texto crudo:

```
"${jwt.secret}"   ← 13 caracteres = 104 bits
```

JJWT exige mínimo **256 bits (32 bytes)** para HMAC-SHA, y rechazó la clave.

**Solución:** añadir el `jwt.secret` al `application.yml` de test (≥32 bytes). Al ser
cambio solo en recursos de test, **no afecta al comportamiento en producción**.

> **Regla práctica:** si añades un nuevo `@Value("${...}")` a un bean que se instancia en
> tests de contexto, recuerda que **toda propiedad que use debe estar también en el
> `application.yml` de test**, si no el contexto de test no arranca.

---

### 12.6 Limpieza — `bin/` ya no se versiona

La carpeta `bin/` de cada servicio (salida de compilación del plugin de Java de VS
Code/Eclipse) estaba **trackeada en git**, pero no era código fuente. Generaba ruido:
aparecía como "modificado" sin que nadie editara nada, porque el contenido versionado
estaba desactualizado respecto a `src/`.

**Solución:** añadir `bin/` y `**/bin/` al `.gitignore` y quitarla del índice con
`git rm -r --cached services/*/bin`. **Los archivos siguen en disco**; solo dejaron de
versionarse. Es reversible.

---

### 12.7 Estado verificado tras los arreglos

| Verificación | Resultado |
|---|---|
| `./gradlew test` (repo completo) | ✅ **52 tests, 0 fallos** (antes: 9 fallos) |
| 8 microservicios | ✅ todos arrancan y responden |
| 6 contenedores de infraestructura | ✅ activos |
| Flujo end-to-end | ✅ círculo → encuentros → positivo → propagación (`CONFIRMED`/`SUSPECT`) → Kafka → notificación |
| `GET /api/v1/admin/settings` ×3 (antes envenenaba la caché) | ✅ 200 |
| `POST /api/v1/health/confirmed` (antes 500) | ✅ 200 |
| Kafka `promotion.status.changed` / `alert.priority` / `circle.fenced` / `audit.identity.accessed` | ✅ mensajes publicados y consumidos |

### 12.8 Archivos modificados en estos arreglos

```
.gitignore                                                        # ignora bin/
services/circleguard-promotion-service/build.gradle.kts           # Testcontainers 1.21.4
services/circleguard-promotion-service/src/main/java/.../AdminController.java
services/circleguard-promotion-service/src/main/resources/application.yml
services/circleguard-promotion-service/src/test/java/.../HealthStatusControllerTest.java
services/circleguard-identity-service/src/main/resources/application.yml
services/circleguard-identity-service/src/test/resources/application.yml
services/circleguard-notification-service/src/main/resources/application.yml
```

### 12.9 Nota de seguridad pendiente

Durante la ejecución de diagnóstico se leyó el contenido de `~/.docker/config.json`,
que contiene **credenciales de Docker Hub en texto decodificable**. Recomendación:
**rotar ese token**. No está relacionado con el código del repo, pero conviene dejarlo
hecho.
