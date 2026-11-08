pipeline {
    agent any

    options {
        skipDefaultCheckout()
        timestamps()
        timeout(time: 40, unit: 'MINUTES')
        buildDiscarder(logRotator(numToKeepStr: '20', artifactNumToKeepStr: '10'))
        disableConcurrentBuilds(abortPrevious: true)
    }

    environment {
        GRADLE_OPTS = '-Dorg.gradle.daemon=false'
    }

    stages {
        stage('Checkout') {
            steps {
                checkout scm
                sh 'git log -1 --format="%h %an: %s"'
            }
        }

        stage('Build') {
            steps {
                sh 'chmod +x gradlew'
                sh './gradlew assemble --console=plain'
            }
        }

        stage('Tests') {
            steps {
                // --continue runs the tests of every service even if one of them fails
                sh './gradlew test --continue --console=plain'
            }
        }
    }

    post {
        always {
            junit allowEmptyResults: true,
                  testResults: 'services/*/build/test-results/test/*.xml'
            archiveArtifacts allowEmptyArchive: true,
                             artifacts: 'services/*/build/reports/tests/**, services/*/build/reports/jacoco/**'
        }
        success {
            echo 'Build and tests passed.'
        }
        failure {
            echo 'Pipeline failed. Check the failed stage and the Tests tab for details.'
        }
    }
}
