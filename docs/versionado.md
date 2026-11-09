# Versionado semántico automático

## Herramienta 

Se usa **semantic-release 24** con el preset **conventionalcommits**. El proyecto ya valida los
mensajes con Conventional Commits (`commitlint.config.mjs`, `.githooks/commit-msg` y el workflow
`Commit lint`), así que el historial de commits es la entrada que semantic-release necesita para
calcular la versión.

La configuración está en [`.releaserc.json`](../.releaserc.json) y el workflow que la ejecuta en
[`.github/workflows/semantic-versioning.yml`](../.github/workflows/semantic-versioning.yml).

## Dónde y cuándo se ejecuta

El workflow se dispara en cada `push` a `main` y `dev` (nunca en pull requests). Usa el
`GITHUB_TOKEN` con `contents: write` para crear y publicar el tag; no requiere secretos adicionales.

| Rama | Tipo de versión | Ejemplo de tag |
|------|-----------------|----------------|
| `main` | Release estable | `v1.2.0` |
| `dev` | Pre-release | `v1.3.0-dev.1` |

## Reglas de incremento

| Commit | Incremento | Ejemplo |
|--------|------------|---------|
| `feat:` | **MINOR** | `1.2.0 → 1.3.0` |
| `fix:` | **PATCH** | `1.2.0 → 1.2.1` |
| `feat!:` / `fix!:` / `BREAKING CHANGE:` en el pie | **MAJOR** | `1.2.0 → 2.0.0` |
| `perf:`, `revert:` | **PATCH** | `1.2.0 → 1.2.1` |
| `docs:`, `test:`, `build:`, `ci:`, `chore:`, `style:`, `refactor:` | Sin release | - |

Si no hay commits que generen release, semantic-release no crea tag. La primera release es `v1.0.0`
(en `dev` es `v1.0.0-dev.1`).

## Cómo verificarlo

1. Hacer merge de un PR con un commit `feat:` a `dev` (o `main`).
2. Revisar la ejecución del workflow **Semantic versioning** en GitHub Actions.
3. Ver los tags publicados:

```bash
git fetch --tags
git tag --sort=-v:refname
git describe --tags --abbrev=0
```

4. Ver el tag en GitHub: `/<owner>/<repo>/tags`.

## Integración con imágenes Docker (Nexus)

El `Jenkinsfile` habilita la publicación de imágenes con `publish: true`. La etapa **Publish images**
de la librería `circleguard-pipeline-library` usa `resolveVersion()`:

- Si el commit tiene un tag de release (`vX.Y.Z` o `vX.Y.Z-dev.N`), la imagen se publica con esa
  versión: `localhost:8082/circleguard/auth-service:1.2.0`.
- Si todavía no hay tag para el commit, se usa una pre-release basada en el último tag:
  `1.2.0-build.15.ab12cd3`.
- Nunca se usa `latest`.

Para que la imagen quede con la versión exacta del release, el tag debe existir cuando corre Jenkins.
El workflow de versionado lo crea en el push; si Jenkins corre antes, el siguiente build ya lo toma.

## Notificaciones por Discord

La librería compartida envía un mensaje a un canal de Discord cuando el pipeline falla. La URL del
webhook se guarda en Jenkins como credencial de tipo **Secret text** con id
`discord-webhook-url`; el `Jenkinsfile` la referencia con `discordCredentialsId`. El step usa
`curl`, así que no requiere plugins adicionales ni servidor SMTP.

## Alcance de esta HU

Esta HU cubre el cálculo de la versión y la creación/publicación del tag. La generación de
*release notes* y la publicación de la **GitHub Release** corresponden a la HU-19 y se agregan como
plugins adicionales en `.releaserc.json` sin cambiar el cálculo de versión.

## Requisitos

- El workflow necesita `permissions: contents: write` (ya configurado).
- Ejecutarse sobre `main` o `dev`, nunca sobre pull requests.
- Los PR deben fusionarse con merge commit (o squash con mensaje Conventional Commits) para que los
  commits lleguen al historial.
