pipeline {
    agent any

    options {
        disableConcurrentBuilds()
        skipDefaultCheckout(true)
    }

    // GitHub Push -> Webhook Relay -> Jenkins GitHub-Webhook-Trigger.
    triggers {
        githubPush()
    }

    stages {
        stage('Checkout') {
            steps {
                checkout scm
            }
        }

        stage('Code prüfen') {
            steps {
                sh '''
                    set -eu
                    bash -n netwatch.sh
                    test -f Dockerfile
                    docker info > /dev/null
                '''
            }
        }

        stage('Docker Build') {
            steps {
                sh '''
                    set -eu
                    docker build -t "netwatch:build-${BUILD_NUMBER}" .
                '''
            }
        }

        stage('Integrationstest') {
            steps {
                withCredentials([usernamePassword(
                    credentialsId: '1',
                    usernameVariable: 'DB_USER',
                    passwordVariable: 'DB_PASSWORD'
                )]) {
                    sh '''
                        set +x
                        set -eu
                        docker run --rm \
                            --network netwatch-net \
                            -e DB_USER \
                            -e DB_PASSWORD \
                            -e RUN_ONCE=1 \
                            "netwatch:build-${BUILD_NUMBER}"
                    '''
                }
            }
        }

        stage('Deployment') {
            steps {
                withCredentials([usernamePassword(
                    credentialsId: '1',
                    usernameVariable: 'DB_USER',
                    passwordVariable: 'DB_PASSWORD'
                )]) {
                    sh '''
                        set +x
                        set -eu
                        docker tag "netwatch:build-${BUILD_NUMBER}" netwatch:latest

                        if docker container inspect netwatch > /dev/null 2>&1; then
                            docker rm -f netwatch
                        fi

                        docker run -d \
                            --name netwatch \
                            --restart unless-stopped \
                            --network netwatch-net \
                            -e DB_USER \
                            -e DB_PASSWORD \
                            -e CHECK_INTERVAL=60 \
                            netwatch:latest
                    '''
                }
            }
        }

        stage('Smoke Test') {
            steps {
                sh '''
                    set -eu
                    attempt=0
                    until docker logs netwatch 2>&1 | grep -q 'Messwerte in MariaDB gespeichert.'; do
                        attempt=$((attempt + 1))
                        if [ "$attempt" -ge 15 ]; then
                            docker logs --tail 50 netwatch
                            exit 1
                        fi
                        sleep 2
                    done
                    test "$(docker inspect -f '{{.State.Running}}' netwatch)" = 'true'
                    echo 'NetWatch läuft und hat Ergebnisse gespeichert.'
                '''
            }
        }
    }
}
