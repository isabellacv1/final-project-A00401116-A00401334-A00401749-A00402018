// CI pipeline defined in the shared library:
// https://github.com/isabellacv1/circleguard-jenkins-library
@Library('circleguard-pipeline-library@main') _

circleguardPipeline(
    integrationTests: true,
    // SonarQube analysis + quality gate (project CircleGuard)
    sonar: true,
    sonarProjectKey: 'CircleGuard',
    // Pushes the images to the Nexus docker-hosted registry from dev and main
    publish: true,
    // Static validation of the IaC (HU2): terraform fmt/validate + trivy
    // misconfiguration scan, inside pinned containers. Those two stages need no
    // AWS credentials and never touch the S3 backend; images are pulled on first use.
    terraformValidate: true,
    trivyScan: true,
    // Terraform plan against the real S3 backend (plan stage, phase 1).
    // DEV only: the library runs it only on the `dev` branch, plans only
    // infra/terraform/envs/dev and injects the `aws-terraform-credentials`
    // identity by name inside the Terraform commands. The plan is kept in the
    // workspace, never archived.
    terraformPlan: true,
    // Terraform apply DEV: applies ONLY the plan this build produced, only for
    // infra/terraform/envs/dev and only on the `dev` branch. The build, commit,
    // root, SHA-256 and age of the plan are re-validated before any credential
    // or `terraform init`/`apply`. PROD stays disabled here: terraformApplyProd
    // and terraformApproval* are intentionally not set.
    terraformApply: true,
    // Trivy Image: scans every image between `docker build` and `docker push`
    // and blocks the publication on HIGH/CRITICAL (opt-in in the library).
    trivyImageScan: true,
    // HU-33: the library defaults only cover the "Parte 1" images, so the full
    // list is declared here. deploy/docker-compose.yml pulls all of them.
    images: [
        [name: 'circleguard/auth-service',         dockerfile: 'services/circleguard-auth-service/Dockerfile',         context: '.'],
        [name: 'circleguard/identity-service',     dockerfile: 'services/circleguard-identity-service/Dockerfile',     context: '.'],
        [name: 'circleguard/promotion-service',    dockerfile: 'services/circleguard-promotion-service/Dockerfile',    context: '.'],
        [name: 'circleguard/form-service',         dockerfile: 'services/circleguard-form-service/Dockerfile',         context: '.'],
        [name: 'circleguard/gateway-service',      dockerfile: 'services/circleguard-gateway-service/Dockerfile',      context: '.'],
        [name: 'circleguard/notification-service', dockerfile: 'services/circleguard-notification-service/Dockerfile', context: '.'],
        [name: 'circleguard/dashboard-service',    dockerfile: 'services/circleguard-dashboard-service/Dockerfile',    context: '.'],
        [name: 'circleguard/file-service',         dockerfile: 'services/circleguard-file-service/Dockerfile',         context: '.'],
        [name: 'circleguard/web',                  dockerfile: 'mobile/Dockerfile',                                    context: 'mobile'],
    ],
    // HU-13: deploy the published images to the dev environment and verify
    // that every component is available.
    deploy: true,
    environment: 'dev',
    services: [
        [name: 'gateway',      port: 8087],
        [name: 'auth',         port: 8180],
        [name: 'identity',     port: 8083],
        [name: 'form',         port: 8086],
        [name: 'promotion',    port: 8088],
        [name: 'notification', port: 8082],
        [name: 'dashboard',    port: 8084],
        [name: 'file',         port: 8085],
        [name: 'web',          port: 8081, path: '/'],
    ],
    // HU-14: the E2E tests gate the promotion dev -> stage, and promoting to
    // prod always waits for a manual approval (input).
    e2e: true,
    promote: true,
    discordCredentialsId: 'discord-webhook-url'
)
