# Evidencia de pruebas CircleGuard

## Pruebas unitarias


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

## Pruebas E2E