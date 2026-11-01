#!/usr/bin/env bash
set -Eeuo pipefail

# NetWatch: ICMP-Ping, MariaDB, Versionshistorie.
# Keine Zugangsdaten in Git: DB_USER / DB_PASSWORD kommen von Jenkins.
DB_HOST="${DB_HOST:-netwatch-db}"
DB_PORT="${DB_PORT:-3306}"
DB_NAME="${DB_NAME:-netwatch}"
CHECK_INTERVAL="${CHECK_INTERVAL:-60}"
MAX_RUNTIME_SECONDS="${MAX_RUNTIME_SECONDS:-3600}"
RUN_ONCE="${RUN_ONCE:-0}"
NETWATCH_VERSION="${NETWATCH_VERSION:-dev}"
NETWATCH_BUILD="${NETWATCH_BUILD:-0}"
NETWATCH_COMMIT="${NETWATCH_COMMIT:-unknown}"

TARGETS=(
  "google-dns|8.8.8.8"
  "cloudflare-dns|1.1.1.1"
)

if [[ -z "${DB_USER:-}" || -z "${DB_PASSWORD:-}" ]]; then
  echo "FEHLER: DB_USER und DB_PASSWORD müssen gesetzt sein." >&2
  exit 1
fi

if [[ ! "$DB_NAME" =~ ^[a-zA-Z][a-zA-Z0-9_]*$ ]]; then
  echo "FEHLER: Ungültiger Datenbankname: $DB_NAME" >&2
  exit 1
fi

for number in "$CHECK_INTERVAL" "$MAX_RUNTIME_SECONDS"; do
  if [[ ! "$number" =~ ^[1-9][0-9]*$ ]]; then
    echo "FEHLER: Intervall und Laufzeit müssen positive Ganzzahlen sein." >&2
    exit 1
  fi
done

if [[ "$RUN_ONCE" != "0" && "$RUN_ONCE" != "1" ]]; then
  echo "FEHLER: RUN_ONCE muss 0 oder 1 sein." >&2
  exit 1
fi

# MYSQL_PWD ist eine pragmatische Jenkins-Testlösung, keine Secrets-Datei.
db_query() {
  MYSQL_PWD="$DB_PASSWORD" mariadb \
    --protocol=TCP --host="$DB_HOST" --port="$DB_PORT" \
    --user="$DB_USER" --database="$DB_NAME" --batch --silent "$@"
}

register_release() {
  # Nur der echte Deployment-Container registriert den Build.
  if [[ "$RUN_ONCE" == "1" ]]; then
    return 0
  fi
  if [[ ! "$NETWATCH_VERSION" =~ ^[0-9]+([.][0-9]+){1,2}$ \
        || ! "$NETWATCH_BUILD" =~ ^[0-9]+$ \
        || ! "$NETWATCH_COMMIT" =~ ^[0-9a-fA-F]{7,40}$ ]]; then
    echo "FEHLER: Versions-/Build-Metadaten fehlen oder sind ungültig." >&2
    return 1
  fi

  db_query -e "INSERT INTO netwatch_release (version, build_number, git_commit, image_tag) VALUES ('$NETWATCH_VERSION', $NETWATCH_BUILD, '$NETWATCH_COMMIT', 'netwatch:${NETWATCH_VERSION}-b${NETWATCH_BUILD}') ON DUPLICATE KEY UPDATE image_tag=VALUES(image_tag);"
  echo "NetWatch v$NETWATCH_VERSION (Jenkins #$NETWATCH_BUILD, Git $NETWATCH_COMMIT) auf DB $DB_NAME"
}

monitor_cycle() {
  echo "[$(date '+%Y-%m-%d %H:%M:%S')] Prüfe Datenbank und Hosts ..."
  if ! db_query -e "SELECT 1 FROM monitoring_results LIMIT 0;" >/dev/null; then
    echo "FEHLER: Tabelle monitoring_results in $DB_NAME nicht erreichbar." >&2
    return 1
  fi

  local sql=$'START TRANSACTION;\n'
  local item name address ping_output status response_time value
  for item in "${TARGETS[@]}"; do
    IFS='|' read -r name address <<< "$item"
    if [[ ! "$name" =~ ^[a-zA-Z0-9_-]+$ || ! "$address" =~ ^[a-zA-Z0-9.:-]+$ ]]; then
      echo "FEHLER: Ungültiges Ziel: $item" >&2
      return 1
    fi

    if ping_output="$(ping -n -c 1 -W 2 "$address" 2>/dev/null)"; then
      status="ONLINE"
      response_time=""
      if [[ "$ping_output" =~ time=([0-9]+([.][0-9]+)?) ]]; then
        response_time="${BASH_REMATCH[1]}"
      fi
      value="${response_time:-NULL}"
    else
      status="OFFLINE"
      value="NULL"
    fi

    echo "  $name ($address): $status, Antwortzeit: ${value} ms"
    sql+="INSERT INTO monitoring_results (name, ip_address, status, response_time_ms) VALUES ('$name', '$address', '$status', $value);"$'\n'
  done
  sql+=$'COMMIT;\n'

  if ! db_query <<< "$sql"; then
    echo "FEHLER: Messwerte konnten nicht gespeichert werden." >&2
    return 1
  fi
  echo "Messwerte in MariaDB gespeichert."
}

register_release
start_seconds=$SECONDS
while true; do
  monitor_cycle

  if [[ "$RUN_ONCE" == "1" ]]; then
    break
  fi

  elapsed=$((SECONDS - start_seconds))
  if (( elapsed >= MAX_RUNTIME_SECONDS )); then
    break
  fi
  remaining=$((MAX_RUNTIME_SECONDS - elapsed))
  sleep_seconds=$CHECK_INTERVAL
  if (( remaining < sleep_seconds )); then
    sleep_seconds=$remaining
  fi
  sleep "$sleep_seconds"

  if (( SECONDS - start_seconds >= MAX_RUNTIME_SECONDS )); then
    break
  fi
done

echo "NetWatch regulär beendet (maximale Laufzeit: ${MAX_RUNTIME_SECONDS}s)."
