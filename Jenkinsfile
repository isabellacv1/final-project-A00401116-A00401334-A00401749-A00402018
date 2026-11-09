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
    // Failure notifications
    discordCredentialsId: 'discord-webhook-url'
)
