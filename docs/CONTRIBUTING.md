# Contributing to CircleGuard

This guide defines how the team writes commit messages. It follows the
[Conventional Commits 1.0.0](https://www.conventionalcommits.org/en/v1.0.0/) specification,
which is also the input for automatic semantic versioning and release notes.

All commit messages are written in **English**.

## Commit message structure

```
<type>(<scope>): <subject>

[optional body]

[optional footer(s)]
```

| Part      | Required | Rules |
|-----------|----------|-------|
| `type`    | Yes      | One of the allowed types below, lowercase. |
| `scope`   | No       | The affected component, lowercase (see [Scopes](#scopes)). |
| `subject` | Yes      | Imperative mood ("add", not "added"), lowercase start, no final period. |
| `body`    | No       | Explains *what* and *why*. Separated from the header by a blank line. |
| `footer`  | No       | `BREAKING CHANGE: <description>` and/or issue references (`Refs: SCRUM-20`). |

The header (`type(scope): subject`) must not exceed **100 characters**.

## Allowed types

| Type       | Use it for                                             | Version bump |
|------------|--------------------------------------------------------|--------------|
| `feat`     | A new feature                                          | **MINOR**    |
| `fix`      | A bug fix                                              | **PATCH**    |
| `perf`     | A performance improvement                              | **PATCH**    |
| `refactor` | Code change that neither fixes a bug nor adds a feature | —           |
| `docs`     | Documentation only                                     | —            |
| `test`     | Adding or updating tests                               | —            |
| `build`    | Build system or dependencies (Gradle, npm, Docker)     | —            |
| `ci`       | CI/CD configuration (Jenkins, GitHub Actions)          | —            |
| `chore`    | Maintenance tasks that do not change src or tests      | —            |
| `style`    | Formatting only, no logic change                       | —            |
| `revert`   | Reverts a previous commit                              | depends      |

### Breaking changes (MAJOR)

A breaking change is marked with `!` after the type/scope **or** with a
`BREAKING CHANGE:` footer. Either one triggers a **MAJOR** version bump.

```
feat(auth)!: replace role management schema
```

```
feat(auth): replace role management schema

BREAKING CHANGE: the roles table was replaced; existing tokens must be reissued.
```

## Scopes

The scope is optional but recommended. Use the name of the affected component:

- Services: `auth`, `identity`, `promotion`, `form`, `gateway`, `notification`, `file`, `dashboard`
- Client: `mobile`
- Platform: `ci`, `infra`, `deploy`, `k8s`, `observability`, `security`
- Other: `docs`, `deps`, `tests`

## Examples

```
feat(promotion): add status cascade with 14-day ttl
fix(gateway): correct signed qr expiration
docs: add contributing guide with commit conventions
test(form): add integration test for kafka publishing
ci: add commit message validation workflow
build(deps): upgrade testcontainers to 1.21.3
feat(auth)!: replace role management schema
```

Invalid examples:

```
Added login            -> missing type, past tense
feat: Add login.       -> uppercase start, final period
enhance: improve login -> "enhance" is not an allowed type (use feat, perf or refactor)
```

## Validation

Commit messages are validated in two places:

1. **Locally (recommended):** a `commit-msg` git hook rejects invalid messages before the
   commit is created. Enable it once per clone:

   ```bash
   git config core.hooksPath .githooks
   ```

2. **On every Pull Request:** the `Commit lint` GitHub Actions workflow validates all the
   commits of the PR against `commitlint.config.mjs`. A PR with invalid commits fails the check.

## Merging Pull Requests

Because release versions are calculated from the commit history, merge Pull Requests with
**"Create a merge commit"** or **"Rebase and merge"** so the individual conventional commits
are preserved. If **"Squash and merge"** is used, edit the squash commit message so it follows
this convention (for example `docs: add pull request template`), not the PR title format.
