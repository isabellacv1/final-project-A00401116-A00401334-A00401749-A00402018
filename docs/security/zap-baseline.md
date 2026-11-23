# OWASP ZAP baseline scan (HU-36 / E2.6)

El pipeline ejecuta un **baseline scan** de OWASP ZAP contra el entorno que el
propio build acaba de desplegar. Es una etapa **opt-in** (`zapScan: true` en el
`Jenkinsfile`) y corre entre **Verify deployment** y **Smoke tests**: el objetivo
ya responde cuando empieza el escaneo, y un hallazgo bloqueante detiene el build
antes de las etapas funcionales, E2E y de promoción.

## Objetivo y modelo de ejecución

- **Objetivo:** `zapTargets: ['http://10.20.2.113/']`, que es exactamente el
  Ingress de `dev` (`k8sIngressUrls.dev`) verificado por `verifyIngress`,
  `smokeTests` y `runE2E`. Si se omite `zapTargets`, la librería deriva el
  objetivo de ese mismo mapa, así que el escaneo nunca apunta a otro despliegue.
- **Herramienta:** imagen oficial fijada `ghcr.io/zaproxy/zaproxy:2.17.0`, nunca
  `:latest`, `:weekly`, `:stable` ni `:bare` (estas últimas no traen
  `zap-baseline.py`). Se ejecuta sin `-p` (la API no autenticada de ZAP no se
  publica fuera del contenedor), con `-m 1`, `-T 10`, `-D 0` y sin `-c` ni `-I`.
- **Workspace:** se monta únicamente el subdirectorio del job en `/zap/wrk`, que
  es el `base_dir` que usa `zap-baseline.py` dentro de Docker. Los informes
  quedan en el workspace y los archiva Jenkins; no se pierden en una capa
  anónima del contenedor.
- **Pre-flight:** antes de arrancar el contenedor se comprueba cada URL con
  `curl`. HTTP `000` o sin respuesta es **fallo técnico**, no un informe limpio
  de cero hallazgos.

## Qué es (y qué no es) un baseline

Es un spider tradicional + las **reglas pasivas** de ZAP: rastrea e inspecciona
respuestas (cabeceras de seguridad ausentes, cookies débiles, errores de CORS,
divulgación de información, superficies que responden 401). **Nunca ataca**.

Limitaciones declaradas, que se reproducen también en el informe consolidado:

- No detecta inyecciones (SQL/NoSQL/command) ni XSS reflejado: eso exige un
  active scan, deliberadamente fuera de esta fase.
- El spider tradicional **no ejecuta JavaScript**, por lo que las llamadas XHR
  de la SPA no se descubren; el spider de cliente (`-j`) está desactivado
  (`zapClientSpider: false`) y su activación es una decisión explícita de una
  fase posterior.
- Sin un OpenAPI importado, los endpoints POST no se rastrean.
- El escaneo es anónimo: los endpoints protegidos responden 401 y su superficie
  queda fuera de este baseline.
- ZAP no tiene severidad `Critical` (su máximo es `High`); la categoría
  `Critical` se mantiene para mantener una política única con Trivy.

## Política de severidad

La decisión se lee de `riskcode` en `site[].alerts[].riskcode` del informe JSON
de ZAP, **no del exit code**. Los exit codes `0`, `1` y `2` son resultados válidos
(el código refleja el ruleset `-c`, que no conoce la severidad); la política se
aplica al JSON:

| Severidad | `riskcode` | Resultado |
|-----------|-----------|-----------|
| Informational / Low | `0` / `1` | solo se contabilizan |
| Medium | `2` | `unstable()` — build inestable, no fallido |
| High / Critical | `3` / `4` | `error()` — build fallido |

La decisión es **agregada**: un solo `High` en cualquier objetivo bloquea el
build completo. El exit `3`, un JSON ausente o ilegible, un `site[]` vacío o un
`riskcode` fuera de `0..4` se tratan como **TECHNICAL FAILURE** con ese prefijo
en el mensaje: nunca como "escaneo limpio".

## Excepciones justificadas

Las excepciones viven en [`.zapignore.yaml`](../../.zapignore.yaml) en la raíz
del repositorio. El archivo existe pero arranca sin entradas activas.

```yaml
exceptions:
  - id: "10015"
    scope: "http://10.20.2.113/.*"   # regex opcional sobre la URL del alert
    statement: >-
      Por qué se acepta el hallazgo, con evidencia y riesgo aceptado.
    approved_by: reviewer
    expired_at: 2027-05-17
```

Reglas:

- `id` debe coincidir con el `pluginid` de ZAP; `scope` es una regex opcional
  sobre la URL del hallazgo.
- `expired_at` es **obligatorio** y debe ser una fecha válida y futura. Sin él,
  con fecha inválida, caducada o con una regex rota, la excepción **no se aplica**
  (fail closed) y el hallazgo vuelve a bloquear; se informa del número de
  excepciones caducadas o inutilizables.
- Una excepción solo cambia la **decisión**, nunca el informe: el hallazgo
  exceptuado sigue visible en el HTML/JSON archivado y se lista en el resumen.

## Evidencia

Cada informe lleva el número de build y un slug del objetivo:

- `zap-report-<build>-<slug>.{html,json,xml,md}` — informes completos, archivados
  y publicados en Jenkins bajo `OWASP ZAP`.
- `zap-summary-<build>.txt` — resumen legible (objetivos, desglose, totales,
  excepciones aplicadas/caducadas y estado `PASS`/`WARN`/`BLOCK`).
- `zap-summary-<build>.xml` — JUnit sintético: los hallazgos aparecen en la
  pestaña **Tests** sin instalar plugins adicionales.
- `quality-report-<build>.{md,html}` — el informe consolidado (E2.7) incluye los
  totales de ZAP junto a JaCoCo, JUnit, SonarQube y Trivy, bajo
  `Coverage & Quality`.

Toda la evidencia se archiva y publica **antes** de que el step falle o marque el
build como inestable: un hallazgo bloqueante nunca borra su propia prueba.

## Seguimiento

- Revisar en el primer build real que el contenedor puede alcanzar el Ingress
  desde el agente Jenkins y que el montaje `volume-subpath` funciona con la
  imagen de ZAP (es la misma garantía pendiente de validación que para los
  demás contenedores de la librería).
- Si aparece un hallazgo aceptable, documentarlo en `.zapignore.yaml` con
  justificación, aprobador y fecha de caducidad; no silenciarlo en el pipeline.
- El active scan, el spider de cliente (`-j`) y la importación de OpenAPI quedan
  como siguiente fase, con su propio análisis de riesgo y tiempo.
