# Evidencia de pruebas CircleGuard

> El pipeline que ejecuta estas pruebas en Jenkins se describe en [`pipeline.md`](pipeline.md).

## Pruebas unitarias

### Contexto

Para los servicios núcleo auth, identity, promotion, form y gateway se debe tener al menos **60 % de cobertura de líneas** para el cual generamos los reportes XML y HTML con JaCoCo. Las pruebas unitarias se escribieron con JUnit 5 y Mockito, de manera que:
- Los *ServiceTest*: prueban la lógica de negocio, ramas, validaciones y excepciones.
- Los *ControllerTest*: prueban códigos HTTP, validación de entradas y errores.

### Estado antes y después (cobertura de líneas, JaCoCo)

| Servicio | Antes | Después |
|---|---|---|
| auth | 28,8% (53/184) | 75% (138/184) |
| identity | 50,4% (68/135) | 77,04% (104/135) |
| promotion | 38% (323/851) | 64,98% (553/851) |
| form | 52,1% (73/140) | 82,14% (115/140) |
| gateway | 81% (17/21) | 80,95% (17/21) |
| notification | 58,2% (110/189) | ---- |
| dashboard | 5,2% (4/77) | ---- |
| file | 21,1% (4/19) | ---- |

**Nota:** Gateway ya cumplía con la cobertura por lo que no se tocó.

### Ejecución y dónde ver los resultados
```bash
./gradlew clean check --continue
```
- Resultados JUnit: *services/<servicio>/build/test-results/test/*.xml*
- Reporte JaCoCo: *services/<servicio>/build/reports/jacoco/test/html/index.html* (y *jacocoTestReport.xml*)
- En Jenkins con **Unit Tests + Coverage**. 

### Hallazgos
1. Promotion necesita Docker incluso en las pruebas unitarias, porque sus pruebas existentes usan Testcontainers.


## Pruebas de integración

### Contexto
Tenemos que saber que CircleGuard funciona como una cadena donde: **una persona reporta síntomas → el sistema cambia su estado → se propaga el riesgo a sus contactos → se notifica.** Los servicios se comunican por Kafka y guardan datos en PostgreSQL y Neo4j. Sabemos que las pruebas unitarias simulan esas dependencias, por lo que no detectan errores de formato de mensaje, nombres de topics ni configuración de consumidores. Para eso las pruebas de integración usan el middleware real (contenedores efímeros con Testcontainers) para comprobarlo.

### Integraciones probadas

| Flujo | Clase | Qué se prueba |
|---|---|---|
| **form → Kafka → promotion → Neo4j** | FormToPromotionKafkaIT | Una encuesta con síntomas viaja por Kafka y promotion actualiza al usuario y a su contacto, y emite el evento de cambio. |
| **promotion → Kafka → notification** | PromotionStatusChangedNotificationIT | El consumidor de notification procesa el evento de cambio de estado y lo despacha a email, SMS, push y LMS. Un mensaje inválido no detiene el procesamiento del siguiente |
| **Propagación por contactos** (promotion con Neo4j, PostgreSQL, Redis y Kafka) | PromotionEncounterPropagationIT | Un caso confirmado pasa al contacto directo a *SUSPECT* y al de segundo grado a *PROBABLE*; un encuentro fuera de ventana (más de 14 días) y un tercer grado no cambian |
| **form → Kafka → PostgreSQL** | HealthSurveyKafkaIT | Form guarda la encuesta y publica survey.submitted con la clave y el payload esperados |

En resumen, son **4 clases y 5 casos**. Las integraciones 1 y 2 cruzan dos servicios por Kafka, mientras la 3 y la 4 prueban un servicio con su middleware real.

**Nota:** Ninguna prueba arranca los servicios como procesos independientes, cada una ejecuta el servicio bajo prueba con su middleware real.

### Cómo ejecutarlas y dónde ver los resultados
```bash
./gradlew integrationTest --continue   
```
- Solo corren las clases con *@Tag("integration")*; no afectan la cobertura del 60% de las pruebas unitarias.
- Resultados: *services/<nombre_servicio>/build/test-results/integrationTest/*.xml*.
- En Jenkins **Integration Tests**, con los resultados JUnit publicados. 

### Hallazgos importantes
1. **Acoplamiento de build.** Promotion compila el código de form en su classpath de pruebas para reutilizar el servicio real en la integración 1.
2. **Alcance.** No se cubren auth ↔ identity ni gateway ↔ Redis, porque se priorizó el flujo de salud. 

## Pruebas E2E con Playwright

### Contexto
Las pruebas unitarias y de integración no detectan fallos que solo ve un usuario en el navegador, por tanto se automatizaron los tres flujos sobre el cliente web real con playwright y Page Object Model en *tests/e2e-playwright/* con auth, form y gateway reales detrás.

| Flujo | Prueba | Qué prueba |
|---|---|---|
| Inicio de sesión | Login válido | Redirige al home y muestra el QR rotativo |
| Inicio de sesión | Login inválido | Aparece el mensaje de error y la URL no cambia |
| Cuestionario de salud | Reporte de síntomas | Se envía el *POST /api/v1/surveys* con el payload correcto y se muestra la confirmación *STATUS: SUSPECT* |
| Validación de acceso | QR vigente | El QR real que emite auth es aceptado por el gateway (*ACCESS GRANTED*) |
| Validación de acceso | QR inválido o expirado | El gateway lo rechaza (*ACCESS DENIED*) |
| Resiliencia | Error HTTP 500 en el envío | El usuario ve el error, no aparece confirmación falsa y la interfaz sigue operativa |


### Ejecución y dónde ver los resultados
```bash
cd tests/e2e-playwright && npm ci && npx playwright install chromium
BASE_URL=http://localhost:8081 E2E_USERNAME=<usuario> E2E_PASSWORD=<clave> npx playwright test
```
- Variables: BASE_URL, AUTH_BASE_URL, GATEWAY_BASE_URL, E2E_USERNAME, E2E_PASSWORD (en Jenkins, por credenciales).
- Reporte HTML: *tests/e2e-playwright/playwright-report/*, JUnit: *tests/e2e-playwright/results.xml*

### Hallazgos de las pruebas

Se identificaron y corrigieron problemas relacionados con la configuración de CORS en el gateway y el servicio de autenticación, la visualización de errores de envío en la pantalla de reportes y la ausencia de atributos testID en las pantallas de login, home, reporte y escáner. También se documentaron limitaciones relacionadas con el cuestionario, la propagación de respuestas y el uso de cámara y biometría en el escáner.