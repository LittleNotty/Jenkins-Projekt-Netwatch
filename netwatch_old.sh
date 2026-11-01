#!/usr/bin/env bash
set -Eeuo pipefail

# NetWatch: ICMP/Ping-Monitoring mit Speicherung in MariaDB.
# DB-Zugangsdaten werden zur Laufzeit über Umgebungsvariablen gesetzt.
DB_HOST="${DB_HOST:-netwatch-db}"
DB_PORT="${DB_PORT:-3306}"
DB_NAME="${DB_NAME:-netwatch}"
CHECK_INTERVAL="${CHECK_INTERVAL:-60}"
RUN_ONCE="${RUN_ONCE:-0}"

# Format: NAME|ADRESSE. Einfach weitere Einträge ergänzen.
TARGETS=(
  "google-dns|8.8.8.8"
  "cloudflare-dns|1.1.1.1"
)

if [[ -z "${DB_USER:-}" || -z "${DB_PASSWORD:-}" ]]; then
  echo "FEHLER: DB_USER und DB_PASSWORD müssen gesetzt sein." >&2
  exit 1
fi

if [[ ! "$CHECK_INTERVAL" =~ ^[1-9][0-9]*$ ]]; then
  echo "FEHLER: CHECK_INTERVAL muss eine positive Ganzzahl sein." >&2
  exit 1
fi

# MYSQL_PWD verhindert, dass das Passwort als CLI-Argument sichtbar wird.
# Die Umgebungsvariable ist kein vollwertiger Secret-Speicher.
db_query() {
  MYSQL_PWD="$DB_PASSWORD" mariadb \
    --protocol=TCP \
    --host="$DB_HOST" \
    --port="$DB_PORT" \
    --user="$DB_USER" \
    --database="$DB_NAME" \
    --batch --silent "$@"
}

monitor_cycle() {
  echo "[$(date '+%Y-%m-%d %H:%M:%S')] Prüfe Datenbank und Hosts ..."

  if ! db_query -e "SELECT 1 FROM monitoring_results LIMIT 0;" >/dev/null; then
    echo "FEHLER: Datenbank oder Tabelle monitoring_results nicht erreichbar." >&2
    return 1
  fi

  local sql=$'START TRANSACTION;\n'
  local item name address ping_output status response_time value

  for item in "${TARGETS[@]}"; do
    IFS='|' read -r name address <<< "$item"

    # Erlaubte Zeichen halten Host-Einträge für SQL und ping eindeutig.
    if [[ ! "$name" =~ ^[a-zA-Z0-9_-]+$ || ! "$address" =~ ^[a-zA-Z0-9.:-]+$ ]]; then
      echo "FEHLER: Ungültiger Target-Eintrag: $item" >&2
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
    echo "FEHLER: Daten konnten nicht in MariaDB gespeichert werden." >&2
    return 1
  fi

  echo "Messwerte in MariaDB gespeichert."
}

while true; do
  monitor_cycle

  if [[ "$RUN_ONCE" == "1" ]]; then
    break
  fi

  sleep "$CHECK_INTERVAL"
done
