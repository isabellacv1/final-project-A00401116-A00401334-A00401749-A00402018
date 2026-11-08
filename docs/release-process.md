# Releases and release notes

Versions, tags, GitHub Releases and release notes are generated automatically by
[semantic-release](https://semantic-release.gitbook.io/) from the commit history. Nobody creates
versions or writes release notes by hand.

| File | Purpose |
|------|---------|
| [`.releaserc.json`](../.releaserc.json) | Branches, version rules and release notes sections. |
| [`.github/workflows/release.yml`](../.github/workflows/release.yml) | Runs semantic-release on every push to `main` and `dev`. |

## How the version is calculated

Commits follow [Conventional Commits](CONTRIBUTING.md). Since the last release, the highest change wins:

| Commit | Example | Version bump |
|--------|---------|--------------|
| Breaking change (`!` or `BREAKING CHANGE:` footer) | `feat(auth)!: replace role management schema` | **MAJOR** `1.4.2 → 2.0.0` |
| `feat` | `feat(promotion): add status cascade with 14-day ttl` | **MINOR** `1.4.2 → 1.5.0` |
| `fix`, `perf`, `revert` | `fix(gateway): correct signed qr expiration` | **PATCH** `1.4.2 → 1.4.3` |
| `docs`, `test`, `ci`, `build`, `refactor`, `chore`, `style` | `docs: update readme` | no release |

If there are no releasable commits, no version is created.

## Branches and tags

| Branch | Version | Tag | GitHub Release |
|--------|---------|-----|----------------|
| `main` | `1.2.0` | `v1.2.0` | Normal release (latest) |
| `dev` | `1.3.0-dev.1`, `1.3.0-dev.2`, ... | `v1.3.0-dev.1` | Pre-release |

- Every merge into `dev` with releasable commits creates a new pre-release of the next version.
- When `dev` is promoted to `main` (PR `dev → main`), the stable version is released (`v1.3.0`).
- Tags always use the format `vX.Y.Z` or `vX.Y.Z-dev.N`.

## Release notes

Each GitHub Release contains the notes generated from the commits, grouped in sections:
Features, Bug Fixes, Performance, Reverts, Refactoring, Tests, CI/CD, Build and Documentation
(`chore` and `style` are hidden). Every entry links to its commit.

Releases are listed in the repository under **Releases** (`/releases`).

## Docker image versions

The Jenkins pipeline (shared library `circleguard-pipeline-library`) tags the images with the same
version:

- A commit with a release tag publishes `circleguard/<service>:1.3.0` (or `:1.3.0-dev.2` on `dev`).
- A commit without a tag publishes a pre-release built from the last tag, for example
  `circleguard/<service>:1.3.0-build.15.ab12cd3`.
- Images are never tagged `latest`.

## Notes

- Merge PRs with **Create a merge commit** so the conventional commits of the branch reach `main`/`dev`.
  If a PR is squashed, the squash message must follow the convention (not the PR title format).
- The workflow uses the default `GITHUB_TOKEN`; no extra secrets are needed.
- semantic-release does not commit back to the branches (no `CHANGELOG.md` commit), because `main`
  and `dev` only accept changes through pull requests. The history lives in the GitHub Releases.
