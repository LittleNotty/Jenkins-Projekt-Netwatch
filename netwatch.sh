#!/usr/bin/env bash
set -Eeuo pipefail

# NetWatch: Ping-Monitoring mit Speicherung in der Versionsdatenbank.
# DB-Zugangsdaten kommen beim Containerstart aus Jenkins Credentials.
DB_HOST="${DB_HOST:-netwatch-db}"
DB_PORT="${DB_PORT:-3306}"
DB_NAME="${DB_NAME:-netwatch_v0_1}"
DB_USER="${DB_USER:-}"
DB_PASSWORD="${DB_PASSWORD:-}"
CHECK_INTERVAL="${CHECK_INTERVAL:-60}"
MAX_RUNTIME_SECONDS="${MAX_RUNTIME_SECONDS:-3600}"
RUN_ONCE="${RUN_ONCE:-0}"
NETWATCH_VERSION="${NETWATCH_VERSION:-}"
NETWATCH_BUILD="${NETWATCH_BUILD:-}"
NETWATCH_COMMIT="${NETWATCH_COMMIT:-}"

# Weitere Ziele einfach nach demselben Schema ergänzen: NAME|IP
TARGETS=(
  "google-dns|8.8.8.8"
  "cloudflare-dns|1.1.1.1"
)

if [[ -z "$DB_USER" || -z "$DB_PASSWORD" ]]; then
  echo "FEHLER: DB_USER oder DB_PASSWORD fehlt." >&2
  exit 1
fi
if [[ ! "$DB_NAME" =~ ^[a-zA-Z][a-zA-Z0-9_]*$ ]]; then
  echo "FEHLER: Ungültiger Datenbankname: $DB_NAME" >&2
  exit 1
fi
for number in "$CHECK_INTERVAL" "$MAX_RUNTIME_SECONDS"; do
  if [[ ! "$number" =~ ^[1-9][0-9]*$ ]]; then
    echo "FEHLER: CHECK_INTERVAL und MAX_RUNTIME_SECONDS müssen positive Ganzzahlen sein." >&2
    exit 1
  fi
done
if [[ "$RUN_ONCE" != "0" && "$RUN_ONCE" != "1" ]]; then
  echo "FEHLER: RUN_ONCE muss 0 oder 1 sein." >&2
  exit 1
fi

# Kein Passwort im Repository oder als Kommandozeilenargument.
# MYSQL_PWD ist für diese Demo pragmatisch, für Produktion wäre eine Secret-Datei besser.
db_query() {
  MYSQL_PWD="$DB_PASSWORD" mariadb \
    --protocol=TCP --host="$DB_HOST" --port="$DB_PORT" \
    --user="$DB_USER" --database="$DB_NAME" --batch --silent "$@"
}

register_release() {
  # Der Integrationstest schreibt Messwerte, aber keinen Deployment-Eintrag.
  [[ "$RUN_ONCE" == "1" ]] && return 0

  if [[ ! "$NETWATCH_VERSION" =~ ^[0-9]+(\.[0-9]+){1,2}$ || \
        ! "$NETWATCH_BUILD" =~ ^[0-9]+$ || \
        ! "$NETWATCH_COMMIT" =~ ^[0-9a-fA-F]{7,64}$ ]]; then
    echo "FEHLER: Versions-, Build- oder Git-Information ungültig." >&2
    return 1
  fi

  db_query -e "INSERT INTO netwatch_release
    (version, build_number, git_commit, image_tag)
    VALUES ('$NETWATCH_VERSION', $NETWATCH_BUILD, '$NETWATCH_COMMIT',
            'netwatch:${NETWATCH_VERSION}-b${NETWATCH_BUILD}')
    ON DUPLICATE KEY UPDATE image_tag = VALUES(image_tag);"
  echo "Deployment: NetWatch v$NETWATCH_VERSION, Jenkins #$NETWATCH_BUILD, Git $NETWATCH_COMMIT"
}

monitor_cycle() {
  echo "[$(date '+%Y-%m-%d %H:%M:%S')] Prüfe Datenbank und Hosts ..."
  db_query -e 'SELECT 1 FROM monitoring_results LIMIT 0;' >/dev/null || {
    echo "FEHLER: Tabelle monitoring_results nicht erreichbar ($DB_NAME)." >&2
    return 1
  }

  local sql=$'START TRANSACTION;\n'
  local target name ip ping_output status response

  for target in "${TARGETS[@]}"; do
    IFS='|' read -r name ip <<< "$target"
    if [[ ! "$name" =~ ^[a-zA-Z0-9_-]+$ || ! "$ip" =~ ^[0-9a-fA-F:.]+$ ]]; then
      echo "FEHLER: Ungültiges Monitoring-Ziel: $target" >&2
      return 1
    fi

    if ping_output="$(ping -n -c 1 -W 2 "$ip" 2>/dev/null)"; then
      status=ONLINE
      response=NULL
      if [[ "$ping_output" =~ time=([0-9]+([.][0-9]+)?) ]]; then
        response="${BASH_REMATCH[1]}"
      fi
    else
      status=OFFLINE
      response=NULL
    fi

    if [[ "$response" == NULL ]]; then
      echo "  $name ($ip): $status, Antwortzeit: n/a"
    else
      echo "  $name ($ip): $status, Antwortzeit: ${response} ms"
    fi

    sql+="INSERT INTO monitoring_results
      (name, ip_address, status, response_time_ms)
      VALUES ('$name', '$ip', '$status', $response);"$'\n'
  done

  sql+=$'COMMIT;\n'
  db_query <<< "$sql" || {
    echo 'FEHLER: Messwerte konnten nicht gespeichert werden.' >&2
    return 1
  }
  echo 'Messwerte in MariaDB gespeichert.'
}

start_seconds=$SECONDS
registered=0
while true; do
  monitor_cycle
  if [[ "$registered" == "0" ]]; then
    register_release
    registered=1
  fi

  [[ "$RUN_ONCE" == "1" ]] && break

  elapsed=$((SECONDS - start_seconds))
  (( elapsed >= MAX_RUNTIME_SECONDS )) && break
  remaining=$((MAX_RUNTIME_SECONDS - elapsed))
  sleep_seconds=$CHECK_INTERVAL
  (( remaining < sleep_seconds )) && sleep_seconds=$remaining
  sleep "$sleep_seconds"
  (( SECONDS - start_seconds >= MAX_RUNTIME_SECONDS )) && break
done

echo "NetWatch regulär beendet (Laufzeitgrenze: ${MAX_RUNTIME_SECONDS}s)."
