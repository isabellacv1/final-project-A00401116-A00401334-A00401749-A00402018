# Jenkins

Jenkins runs the CI pipeline of CircleGuard.

- **Server:** provisioned with [`infra/bootstrap/jenkins`](../../infra/bootstrap/jenkins) (HU-05).
- **Global configuration and credentials:** [`infra/config-as-code/jenkins`](../../infra/config-as-code/jenkins).
- **CI job:** multibranch job `circleguard`, defined in [`infra/jenkins/jobs/circleguard.xml`](../../infra/jenkins/jobs/circleguard.xml).
- **Pipeline:** shared library [`circleguard-jenkins-library`](https://github.com/isabellacv1/circleguard-jenkins-library),
  registered in Jenkins as `circleguard-pipeline-library`. The [`Jenkinsfile`](../../Jenkinsfile) at the root
  of the repository only loads the library and passes the parameters (HU-11).

## Shared library

| Setting | Value |
|---------|-------|
| Name in Jenkins | `circleguard-pipeline-library` |
| Repository | `https://github.com/isabellacv1/circleguard-jenkins-library.git` (public, no credentials needed) |
| Default version | `main` (can be overridden with `@Library('circleguard-pipeline-library@<branch>')`) |
| Where | **Manage Jenkins → System → Global Trusted Pipeline Libraries** |

`Jenkinsfile`:

```groovy
@Library('circleguard-pipeline-library@main') _

circleguardPipeline(
    integrationTests: true,
    sonar: false,
    publish: true,
    deploy: true,
    environment: 'dev',
    discordCredentialsId: 'discord-webhook-url'
)
```

The available parameters and steps are documented in the library README. To keep the registration when
Jenkins is rebuilt, add the `globalLibraries` block from that README to
`infra/config-as-code/jenkins/jenkins.yaml`.

## Access

- **URL:** `http://<jenkins-host>:8080`. The host is shared in the team channel; it is not published
  here because the repository is public.
- **User:** ask the team for an account. Do not share credentials in the repository, PRs or issues.

## How it is connected to GitHub

```
GitHub (push / pull_request)
   │  webhook
   ▼
smee.io channel ──► smee-client container ──► Jenkins /github-webhook/
                                                   │
                                                   ▼
                                     Multibranch job "circleguard"
                                     (scans branches and PRs, runs the Jenkinsfile)
                                                   │
                                                   ▼
                                     Build status reported back to GitHub
```

| Piece | Where | Notes |
|-------|-------|-------|
| GitHub webhook | Repo **Settings → Webhooks** | Points to the team's smee.io channel. Events: push, pull_request, create, delete. |
| smee-client | `infra/bootstrap/jenkins/docker-compose.yml` | Forwards the webhook to Jenkins, which has no public HTTPS endpoint. |
| GitHub credential | Jenkins credential `git-credential` | Username + token used to read the repository and report build status to GitHub. |
| Multibranch job | Jenkins job `circleguard` | Definition versioned in `infra/jenkins/jobs/circleguard.xml`. |

### Multibranch job settings

- **Source:** GitHub, `isabellacv1/final-project-A00401116-A00401334-A00401749-A00402018`.
- **Branches:** every branch that has a `Jenkinsfile`, except branches that already have an open PR
  (those are built as PRs).
- **Pull requests:** PRs from the same repository, built merged with their target branch.
- **Triggers:** the webhook starts a build on every push. A periodic scan every 30 minutes is kept as a
  fallback in case a webhook is lost.
- **Deleted branches:** their jobs are removed on the next scan.

### Status checks reported to GitHub

| Context | When |
|---------|------|
| `continuous-integration/jenkins/branch` | Build of a branch. |
| `continuous-integration/jenkins/pr-merge` | Build of a PR merged with its target branch. Required to merge into `dev` and `main` (HU-12). |

## Pipeline stages

| Stage | Command | Timeout |
|-------|---------|---------|
| Checkout | `checkout scm` | - |
| Build | `./gradlew assemble` | 30 min |
| Tests | `./gradlew test --continue` | 45 min |
| Integration tests | `./gradlew integrationTest --continue` | 30 min |
| SonarQube | analysis + quality gate | off (`sonar: false`) |
| Publish images | `docker build` + `docker push` to Nexus | 40 min (`publish: true`) |
| Deploy | SSH to the environment, `docker compose pull` + `up -d --wait` | 20 min (`deploy: true`, branch in `deployBranches`) |
| Verify deployment | HTTP check of the six components with retries | 15 min (`deploy: true`) |

The deployment pulls the images published by the same build (semantic version, never `latest`)
from `100.31.132.57:8082` and reads the environment configuration from
[`deploy/environments`](../../deploy/environments). Only the `dev` branch deploys automatically;
`stage` and `prod` are promoted in the version promotion flow. See [`deploy/README.md`](../../deploy/README.md).

After every run, even if a stage fails, Jenkins publishes the JUnit results and archives the test and
JaCoCo reports. Performance benchmarks are not part of the pipeline; run them with
`./gradlew performanceTest`.

When a build fails, the shared library sends a Discord message with the job, build number, branch,
commit and build URL. The webhook URL is stored in Jenkins as a **Secret text** credential with id
`discord-webhook-url` (configured by `infra/config-as-code/jenkins/configure-jenkins.sh` or manually
in **Manage Jenkins → Credentials**). The images are tagged with the semantic version resolved from
the Git tags (see [versionado.md](../versionado.md)), never with `latest`.

### Testcontainers inside Jenkins

Jenkins runs in a container and uses the host Docker daemon through `/var/run/docker.sock`, so the
containers started by Testcontainers are siblings of Jenkins, not children. They are only reachable
through the gateway of the host `bridge` network. The library step `configureTestcontainers()` sets
`TESTCONTAINERS_HOST_OVERRIDE` to that gateway before running the tests.

### Resources

The pipeline and the Testcontainers tests need memory and disk. With 1 GB of RAM and 14 GB of disk
the builds took more than 40 minutes and Jenkins took the node offline when free disk dropped below
1 GB. With 8 GB of RAM a full build takes about 7 minutes. If the node goes offline because of disk
space, free it with `docker system prune -af` on the host.

## Running the pipeline

- **Automatically:** push to any branch or open/update a PR. The build starts within a few seconds.
- **Manually:** open the `circleguard` job, select the branch or PR and click **Build Now**.
- **Rescan branches:** in the `circleguard` job click **Scan Repository Now** (useful after creating a
  branch if the webhook did not arrive).

## Reading the results

- **Stage view:** shows which stage failed.
- **Tests tab:** JUnit results of every service, with the failed tests and their stack traces.
- **Build Artifacts:** HTML test reports and JaCoCo coverage reports of every service.
- **GitHub:** the build status is shown on the commit and on the PR checks.

## Recreating the job

If Jenkins is rebuilt, create the job again from the versioned definition:

```bash
JENKINS_URL=http://<jenkins-host>:8080
CRUMB=$(curl -s -c cookies -u <user>:<token> "$JENKINS_URL/crumbIssuer/api/json" \
  | python3 -c "import json,sys;d=json.load(sys.stdin);print(d['crumbRequestField']+':'+d['crumb'])")
curl -s -b cookies -u <user>:<token> -H "$CRUMB" -H "Content-Type: application/xml" \
  -X POST --data-binary @infra/jenkins/jobs/circleguard.xml "$JENKINS_URL/createItem?name=circleguard"
```

The credential `git-credential` and the shared library `circleguard-pipeline-library` must exist in
Jenkins before running the job. Then click **Scan Repository Now** in the job.
