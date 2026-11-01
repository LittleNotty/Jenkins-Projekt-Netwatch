pipeline {
    agent any

    options {
        disableConcurrentBuilds()
        skipDefaultCheckout(true)
    }

    triggers {
        githubPush()
    }

    stages {
        stage('Checkout') {
            steps {
                checkout scm
            }
        }

        stage('Build (Vorbereitung)') {
            steps {
                sh '''
                    set -eu
                    test -f netwatch.sh
                    test -f test.sh
                    test -f Dockerfile
                    test -f Version.txt
                    test -f compose.yaml
                    docker info > /dev/null
                    docker compose version
                    docker compose -p netwatch -f compose.yaml config -q

                    # Die Datenbank muss vor diesem Build unter Compose uebernommen sein.
                    test "$(docker inspect -f '{{ index .Config.Labels "com.docker.compose.project" }}' netwatch-db)" = netwatch
                    test "$(docker inspect -f '{{.State.Health.Status}}' netwatch-db)" = healthy
                '''
                script {
                    def version = readFile('Version.txt').trim()
                    if (!(version ==~ /^[0-9]+(\.[0-9]+){1,2}$/)) {
                        error('Version.txt muss z. B. 0.1 oder 1.2.3 enthalten.')
                    }
                    env.NETWATCH_VERSION = version
                    env.DB_NAME = 'netwatch_v' + version.replace('.', '_')
                    env.IMAGE_TAG = "netwatch:${version}-b${env.BUILD_NUMBER}"
                    env.NETWATCH_BUILD = env.BUILD_NUMBER
                    env.NETWATCH_COMMIT = sh(script: 'git rev-parse HEAD', returnStdout: true).trim()
                    echo "Version ${env.NETWATCH_VERSION} | Datenbank ${env.DB_NAME} | Image ${env.IMAGE_TAG}"
                }
            }
        }

        // Kein Image-Build und kein Deployment nach fehlgeschlagenen Tests.
        stage('Tests (Syntax und Funktion)') {
            steps {
                sh '''
                    set -eu
                    bash -n netwatch.sh
                    bash -n test.sh
                    bash test.sh
                '''
            }
        }

        stage('Docker Image erstellen') {
            steps {
                sh '''
                    set -eu
                    docker build -t "$IMAGE_TAG" .
                '''
            }
        }

        stage('Versionsdatenbank vorbereiten') {
            steps {
                withCredentials([usernamePassword(
                    credentialsId: '1',
                    usernameVariable: 'DB_USER',
                    passwordVariable: 'DB_PASSWORD'
                )]) {
                    sh '''
                        set +x
                        set -eu
                        : "${DB_USER:?DB_USER fehlt}"
                        : "${DB_PASSWORD:?DB_PASSWORD fehlt}"

                        # Einmaliger Compose-Container fuer SQL-DDL, kein zweiter DB-Dienst.
                        docker compose -p netwatch -f compose.yaml run --rm -T --no-deps \
                            --entrypoint bash netwatch -ec '
                                set -eu
                                export MYSQL_PWD="$DB_PASSWORD"
                                mariadb --protocol=TCP -h netwatch-db -u "$DB_USER" \
                                    -e "CREATE DATABASE IF NOT EXISTS $DB_NAME;"
                                mariadb --protocol=TCP -h netwatch-db -u "$DB_USER" \
                                    --database="$DB_NAME" -e "
                                        CREATE TABLE IF NOT EXISTS monitoring_results (
                                            id INT NOT NULL AUTO_INCREMENT PRIMARY KEY,
                                            name VARCHAR(255) NOT NULL,
                                            ip_address VARCHAR(45) NOT NULL,
                                            checked_at DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP,
                                            status VARCHAR(20) NOT NULL,
                                            response_time_ms DECIMAL(10,2) NULL,
                                            INDEX idx_ip_checked_at (ip_address, checked_at)
                                        );
                                        CREATE TABLE IF NOT EXISTS netwatch_release (
                                            id INT NOT NULL AUTO_INCREMENT PRIMARY KEY,
                                            version VARCHAR(32) NOT NULL,
                                            build_number INT NOT NULL,
                                            git_commit VARCHAR(64) NOT NULL,
                                            image_tag VARCHAR(128) NOT NULL,
                                            deployed_at DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP,
                                            UNIQUE KEY uq_build_number (build_number)
                                        );
                                    "
                            '
                        echo "Versionsdatenbank $DB_NAME mit Tabellen vorbereitet."
                    '''
                }
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
                        : "${DB_USER:?DB_USER fehlt}"
                        : "${DB_PASSWORD:?DB_PASSWORD fehlt}"
                        # Testet echte Ping-/MariaDB-Verbindung, beendet sich nach einem Lauf.
                        docker compose -p netwatch -f compose.yaml run --rm -T --no-deps \
                            -e RUN_ONCE=1 netwatch
                    '''
                }
            }
        }

        stage('Deployment (max. 1 Stunde)') {
            steps {
                withCredentials([usernamePassword(
                    credentialsId: '1',
                    usernameVariable: 'DB_USER',
                    passwordVariable: 'DB_PASSWORD'
                )]) {
                    sh '''
                        set +x
                        set -eu
                        : "${DB_USER:?DB_USER fehlt}"
                        : "${DB_PASSWORD:?DB_PASSWORD fehlt}"
                        test "$(docker inspect -f '{{.State.Health.Status}}' netwatch-db)" = healthy

                        # Verhindert das Ersetzen eines fremden/manuell gestarteten Containers.
                        if docker container inspect netwatch > /dev/null 2>&1; then
                            owner="$(docker inspect -f '{{ index .Config.Labels "com.docker.compose.project" }}' netwatch)"
                            if [ "$owner" != netwatch ]; then
                                echo 'FEHLER: Container netwatch wird nicht von Compose verwaltet.' >&2
                                exit 1
                            fi
                        fi

                        docker tag "$IMAGE_TAG" netwatch:latest
                        # Nur die Anwendung ersetzen: DB-Container und Volume bleiben in Ruhe.
                        docker compose -p netwatch -f compose.yaml up -d \
                            --no-deps --force-recreate netwatch
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
                            docker logs --tail 50 netwatch || true
                            exit 1
                        fi
                        sleep 2
                    done
                    test "$(docker inspect -f '{{.State.Running}}' netwatch)" = true
                    test "$(docker inspect -f '{{ index .Config.Labels "com.docker.compose.project" }}' netwatch)" = netwatch
                    echo "NetWatch $NETWATCH_VERSION (Build #$BUILD_NUMBER) läuft via Docker Compose mit DB $DB_NAME."
                '''
            }
        }
    }

    post {
        success {
            echo "NetWatch Build #${env.BUILD_NUMBER}: Erfolgreich!"
        }
        failure {
            echo "FEHLER: NetWatch Build #${env.BUILD_NUMBER} fehlgeschlagen!"
            echo "Details: ${env.BUILD_URL}console"
        }
    }
}
