# Registro de uso de IAG

## 1. Declaración de nivel y alcance

- **Nivel de uso:** Nivel 3 — Colaboración con IAG (con registro de prompts).
- **Alcance:** la IAG se usó como apoyo para [completar, revisar, documentar, depurar,
  generar pruebas, etc.]. El equipo revisó, adaptó y verificó cada resultado antes de
  incorporarlo.

## 2. Integrantes

| Integrante | Uso principal de IAG |
|------------|----------------------|
| Santiago Grajales | Código e infraestructura |
| Melissa Hurtado | infraestructura principalmente |
| Isabella Cuervo | Código e infraestructura |
| Valentina Tobar | pruebas y código |

Cada uno hizo un resumen del uso que le dio a la IA y algunos prompts especificos que fueron usados y agregamos la reflexión crítica.

## 3. Bitácora de prompts - Parte 1

#### Resumen de prompts y uso dado a la IA

Usé la IAG para entender cómo automatizar la infraestructura de CI/CD y no repetir pasos manuales. Le pedí una estrategia para automatizar la configuración de Nexus, Jenkins y SonarQube, por ejemplo la creación de roles y repositorios, de modo que no hubiera que repetir siempre los mismos pasos a mano cada vez que se reconstruye el entorno. También le pedí que me explicara cómo funciona AWS CLI para validar el estado de las instancias, y que me ayudara a escribir un script que comprobara que las instancias están activas usando esa herramienta.

Por último, le pregunté cómo comunicar tres instancias mediante scripts, de forma que una pueda ordenar un despliegue en otra cuando pasen las pruebas E2E, y que el despliegue en la tercera quede sujeto a una aprobación manual. Para verificar se ejecutó el script contra las instancias reales comparando con lo que muestra la consola de AWS, corrigiendo lo que no aparecía y ajustando lo que veíamos necesario.

Usé la IAG sobre todo para entender antes de hacer. Al empezar le di las historias de usuario y los talleres del curso para que me ayudara a entender el proyecto y a ordenar las tareas y las evidencias de la entrega 1. Para las pruebas de integración y E2E le pedí que me explicara un problema con el cliente web que no podía validar el QR indicandome para qué servía el cambio de `Alert` en web. Le pedí que me ayudará a entender algunos flujos dentro de CircleGuard para lograr comprender e implementar pruebas realmente de valor. Me apoyé en la redacción y corrección de algunas pruebas unitarias y de integración. Me explicó como separar la integración de las unitarias mediante la cobertura también de JaCoCo.

Para el versionado semántico le pedí que me explicara cómo funciona, dónde se ve la versión y qué es un tag, por qué elegir `semantic-release` en lugar de un script propio. Verifiqué su recomendación con una demostración en un repositorio aislado. Pregunté acerca de la configuración de un webhook de Discord desde cero para las notificaciones de Jenkins, y probé el envío antes de conectarlo al pipeline. Por último, le pedí me ayudará a concretar los diagramas de arquitectura y del pipeline, centrados en lo que cada componente realmente tiene fueron generados en Mermaid, y los contrasté con el código y con la auditoría de la rúbrica para no dibujar conexiones ni etapas que no existen.

## 5. Reflexión crítica

**Qué funcionó bien:**
La IAG nos ayudó a entender CircleGuard con todo el sistema y los servicios entendiendo cómo viaja una encuesta de salud por Kafka hasta promotion y de ahí a las notificaciones, y por qué cada servicio guarda sus datos donde los guarda. También nos hizo ver cosas que no conocíamos o no teníamos presentes mediante la explicación de algunos erroresque tuvimos. Sirvio como una guía en el proceso.

**Qué no funcionó o requirió corrección:**
A veces especulaba, inventando o haciendo lo que no debía. Por ejemplo hubo momentos donde decía que se había ejecutado correctamente algún código por los resultados pero aún habían errores que no estaban siendo tenidos en cuenta o se daba como realizada alguna tarea teniendo aún mejoras y correciones necesarias por implementar. Casi siempre la respuesta sonaba segura pero en algunas ocasiones pudimos ver el error al contrastarla con el código, con el enunciado o con una ejecución real.

**Qué aprendió el equipo:**
Aprendimos que la IAG se puede usar como herramienta, pero hay que aprender a usarla bien. Sabemos que tenemos que verificar siempre contra el código, el enunciado o una ejecución real. También creemos útil pedir que marque lo que no puede confirmar, en lugar de aceptar una respuesta completa pero inventada.

Aprendimos además que puede hacernos tardar más en algo que podíamos resolver nosotros mismos, sobre todo cuando la tarea era pequeña y le dedicamos varias vueltas de prompts. En varios momentos, el análisis que debía hacerse era más apropiado si lo hacíamos nosotros, porque conocíamos el contexto del equipo y del curso como qué se esperaba del taller, qué estaba haciendo cada compañero o qué riesgo era razonable tomar. Por eso la dejamos como apoyo y no como quien decide ya que las decisiones de alcance las tomamos nosotros y solo entregamos lo que pudimos explicar.

## 6. Registro IAG — Parte 2

### Resumen de prompts y uso dado a la IA

Durante la segunda parte del proyecto utilizamos la IA principalmente como una herramienta de apoyo para comprender conceptos técnicos, comparar alternativas de diseño y acelerar la resolución de problemas concretos del pipeline, la infraestructura y Kubernetes. No se tomó como una fuente definitiva ya que cada respuesta fue revisada por el equipo y contrastada con el código, las pruebas locales, los logs de Jenkins y el comportamiento real de los recursos en AWS.

La IA ayudó en tres frentes: explicar tecnologías nuevas como K3s, Kustomize, RBAC o backend remoto de Terraform, proponer procedimientos seguros para migraciones, recuperación de estados y controles de aprobación, y asistir en el diagnóstico de fallos puntuales del pipeline, incluyendo la interpretación de errores y la propuesta de pruebas de regresión. En todos los casos, la decisión final quedó en el equipo y se validó antes de incorporarla al desarrollo.

### Resumen por integrante

**Melissa:** usó la IA para tomar las decisiones de los patrones de diseño. No le pidió que eligiera por ella, sino que le ayudara a entender por qué un patrón era pertinente en CircleGuard y otro no, a partir de los problemas reales del código y de las restricciones de la infraestructura. Así se llegó a External Configuration para la configuración, a la combinación de health checks, restart policy, timeouts, retry y circuit breaker para la resiliencia, y a Rolling Update + Canary para el despliegue. Cada decisión la contrastó con los recursos de Terraform, las cuotas de Kubernetes y las pruebas de fallos antes de documentarla.

**Santiago:** utilizó la IA para diseñar y operar la infraestructura en AWS. Sus consultas giraron en torno al backend S3 de Terraform, cifrado y protección del bucket, migración de estados locales, aprovisionamiento de K3s, manejo seguro del token de unión y recuperación de nodos. La IA me ayudó a identificar riesgos y a definir procedimientos controlados que luego se aplicaron y verificaron por etapas.

**Valentina:** empleó la IA para comprender y construir la parte de Kubernetes. Consultó sobre K3s, namespaces, RBAC, Deployment/Service/Ingress, Kustomize y StatefulSets. Las respuestas se validaron revisando manifiestos, permisos y el comportamiento del despliegue en Jenkins.

### Tabla de ejemplos concretos de uso

| Integrante | Pregunta o consulta realizada a la IA | Aporte de la IA | Decisión o validación realizada |
|---|---|---|---|
| Melissa | ¿Qué patrón de configuración es el pertinente para CircleGuard y por qué no otro? | Explicó que el problema era de parametrización (secretos en texto plano y valores por ambiente dentro de la imagen) y comparó External Configuration con Feature Toggle, Spring Profiles, Spring Cloud Config y Vault. | Se eligió External Configuration porque reutiliza las variables de entorno de Spring y el canal de inyección que ya tenía el pipeline, sin agregar infraestructura; Vault quedó como evolución futura. |
| Melissa | ¿Qué patrones de resiliencia tienen sentido si el healthcheck solo abría el puerto y los clientes HTTP no tenían timeouts? | Relacionó cada problema con un patrón: liveness/readiness con Actuator para detectar, restart policy para recuperarse, y timeout, retry y circuit breaker con Resilience4j para contener el fallo. | Se implementaron los patrones y se comprobó su efecto con pruebas de inyección de fallos (detener dependencias y procesos) en lugar de darlos por buenos solo por estar configurados. |
| Melissa | ¿Qué patrón de despliegue conviene con un solo nodo en dev y stage y una cuota de 3072 Mi? | Propuso criterios de decisión (usuarios expuestos, recursos, caída, rollback, componentes nuevos, errores de lógica) y evaluó Recreate, Rolling Update, Blue-Green, Canary, Shadow y A/B testing. | Se eligió Rolling Update + Canary: Blue-Green completo no cabe en la cuota (4608 Mi frente a 3072 Mi) y Shadow o A/B exigen un service mesh. Se verificaron los cálculos contra los manifiestos y la cuota real. |
| Santiago | ¿Cómo gestionar de forma centralizada y segura los estados de Terraform para DEV, STAGE y PROD? | Explicó alternativas de almacenamiento remoto y propuso Amazon S3 con estados independientes, versionado y bloqueo nativo. | Se aprobó un backend S3 con `use_lockfile`, sin DynamoDB, manteniendo separados los estados de los tres entornos. |
| Santiago | ¿Qué controles de seguridad deberíamos implementar para proteger el bucket que almacena los estados? | Identificó cifrado, bloqueo de acceso público, TLS obligatorio, versionado y protección contra eliminación accidental. | Se validó la creación del bucket mediante un proyecto Terraform independiente para evitar dependencias circulares. |
| Santiago | ¿Cómo compartir de forma segura el token de unión entre el servidor y el agente de producción? | Propuso AWS Systems Manager Parameter Store con `SecureString`, permisos IAM específicos y archivos temporales protegidos. | Se implementó la publicación y recuperación del token sin exponerlo en Terraform, outputs ni logs. |
| Valentina | ¿Cómo funciona RBAC en Kubernetes y qué permisos necesita Jenkins para realizar despliegues? | Explicó ServiceAccount, Role, RoleBinding y el principio de mínimo privilegio. | Se configuró una cuenta de servicio para Jenkins y se revisaron los permisos de despliegue. |
| Valentina | ¿Qué ventajas tiene utilizar Kustomize con una configuración base y overlays para DEV, STAGE y PROD? | Explicó la reutilización de manifiestos base y la personalización por ambiente sin duplicar archivos. | Se organizó la infraestructura mediante una estructura base y overlays independientes para cada ambiente. |
| Valentina | ¿Por qué falla el despliegue de Jenkins si los manifiestos Kustomize se generan correctamente? | Interpretó el log del build e identificó el uso incompatible de un nombre de contexto junto con `--current`. | Se propuso eliminar `--current`, conservando el nombre explícito del contexto, y se validó con pruebas locales. |


### Reflexión crítica

**Qué funcionó bien:**
La IAG continuó siendo una herramienta de apoyo que nos permitió avanzar en momentos en los que no comprendíamos algún error o no lográbamos identificar por qué algo no funcionaba. También nos ayudó a explorar formas de mejorar nuestras implementaciones y fortalecer las ideas que teníamos. Fue un apoyo para validar nuestro trabajo y encontrar alternativas, pero no un reemplazo de nuestras responsabilidades, ya que las decisiones y los resultados siempre fueron revisados por el equipo, incluyendo las respectivas Pull Requests.

**Qué no funcionó o requirió corrección:**
En varias ocasiones fue necesario refinar los prompts, ya que la IA podía interpretar incorrectamente las instrucciones, inventar soluciones o proponer cambios que no correspondían con lo que realmente necesitábamos. Por esto, fue fundamental mantener una revisión constante de sus respuestas. También hubo situaciones en las que realizaba validaciones repetitivas o innecesarias, incluso cuando ya habíamos comprobado que algo funcionaba, lo que podía generar demoras en lugar de agilizar el trabajo.

**Qué aprendió el equipo:**
Realmente aprendimos que el pensamiento crítico y el razonamiento humano siguen siendo fundamentales, ya que como equipo sí conocemos el contexto del proyecto, sus necesidades y los objetivos que queremos alcanzar, por lo que somos responsables de orientar y evaluar las soluciones. No podemos confiar ciegamente en los resultados de la IA, sino utilizarlos con criterio y validar que realmente respondan a lo que necesitamos.

También comprendimos que, aunque la IA puede facilitar muchas tareas, no siempre es la opción más eficiente. En ocasiones, intentar resolver un problema directamente puede tomar menos tiempo que orientar a la herramienta cuando interpreta mal el contexto o propone soluciones innecesariamente complejas.

