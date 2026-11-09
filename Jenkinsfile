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
    // HU-13: deploy the published images to the dev environment and verify
    // that every component is available.
    deploy: true,
    environment: 'dev',
    // HU-14: the E2E tests gate the promotion dev -> stage, and promoting to
    // prod always waits for a manual approval (input).
    e2e: true,
    promote: true,
    discordCredentialsId: 'discord-webhook-url'
)
