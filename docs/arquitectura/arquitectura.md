# Arquitectura de CircleGuard

El diagrama representa los servicios del proyecto, sus dependencias de datos y los
principales canales de comunicación. La aplicación web consume los servicios
directamente; `gateway-service` valida códigos QR de acceso y no actúa como API
Gateway.

```mermaid
flowchart LR
    User[Usuario / personal de salud]
    Web[Aplicación web<br/>mobile/ · Expo / React Native]

    subgraph Services[Servicios Spring Boot]
        Auth[Auth Service<br/>8180]
        Identity[Identity Service<br/>8083]
        Promotion[Promotion Service<br/>8088]
        Form[Form Service<br/>8086]
        Gateway[Gateway Service<br/>8087 · validación QR]
        Dashboard[Dashboard Service<br/>8084]
        File[File Service<br/>8085]
        Notification[Notification Service<br/>8082]
    end

    subgraph Infrastructure[Datos y mensajería]
        PostgreSQL[(PostgreSQL<br/>bases separadas por servicio)]
        Neo4j[(Neo4j<br/>grafo de contactos)]
        Redis[(Redis<br/>estado y validación QR)]
        Kafka[(Kafka<br/>eventos)]
        LDAP[(OpenLDAP)]
    end

    Channels[SMTP / SMS / notificaciones push]

    User --> Web
    Web -->|HTTP| Auth
    Web -->|HTTP| Identity
    Web -->|HTTP| Promotion
    Web -->|HTTP| Form
    Web -->|HTTP| Gateway
    Web -->|HTTP| Dashboard
    Web -->|HTTP| File

    Auth --> PostgreSQL
    Auth --> LDAP
    Auth -->|HTTP| Identity
    Identity --> PostgreSQL
    Identity -->|publica audit.identity.accessed| Kafka
    Form --> PostgreSQL
    Form -->|publica survey.submitted y certificate.validated| Kafka
    Promotion --> PostgreSQL
    Promotion --> Neo4j
    Promotion --> Redis
    Promotion -->|publica estados y alertas; consume encuestas| Kafka
    Gateway --> Redis
    Dashboard --> PostgreSQL
    File -->|archivos| Disk[(Disco local)]
    Notification -->|consume estados y alertas| Kafka
    Notification --> Channels
```

En desarrollo, `docker-compose.dev.yml` define PostgreSQL, Neo4j, Redis, Kafka,
Zookeeper y OpenLDAP. `docker-compose.app.yml` incluye Auth, Identity, Promotion,
Form, Gateway y la aplicación web. Dashboard, File y Notification están en el
código, pero no forman parte de ese archivo Compose.
