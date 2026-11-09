// CI pipeline defined in the shared library:
// https://github.com/isabellacv1/circleguard-jenkins-library
@Library('circleguard-pipeline-library@main') _

circleguardPipeline(
    integrationTests: true,
    sonar: false,
    publish: true,
    // HU-13: deploy the published images to the dev environment and verify
    // that every component is available (stage/promotion come in the next HU).
    deploy: true,
    environment: 'dev',
    discordCredentialsId: 'discord-webhook-url'
)
