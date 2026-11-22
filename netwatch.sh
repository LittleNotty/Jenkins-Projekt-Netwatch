#!/usr/bin/env bash
set -Eeuo pipefail

# NetWatch: Ping-Messwerte erfassen und in der zur Version gehörenden DB speichern.
# Jenkins bestimmt den Datenbanknamen aus Version.txt und liefert die Zugangsdaten.

# --- Konfiguration ----------------------------------------------------------
# Die Werte stammen aus der Container-Umgebung (Jenkins -> Docker Compose).
# Ein fehlender DB_NAME ist ein Fehler; es darf KEIN stiller Versions-Fallback gelten.
DB_HOST="${DB_HOST:-netwatch-db}"
DB_PORT="${DB_PORT:-3306}"
DB_NAME="${DB_NAME:-}"
DB_USER="${DB_USER:-}"
DB_PASSWORD="${DB_PASSWORD:-}"

CHECK_INTERVAL="${CHECK_INTERVAL:-60}"           # Pause zwischen zwei Durchlaeufen (Sekunden)
MAX_RUNTIME_SECONDS="${MAX_RUNTIME_SECONDS:-3600}" # Maximale Laufzeit des Containers
RUN_ONCE="${RUN_ONCE:-0}"                     # 1 = ein Durchlauf, z. B. für den Integrationstest

# Jenkins-Metadaten für den Deployment-Eintrag in netwatch_release.
NETWATCH_VERSION="${NETWATCH_VERSION:-}"
NETWATCH_BUILD="${NETWATCH_BUILD:-}"
NETWATCH_COMMIT="${NETWATCH_COMMIT:-}"

# Format pro Ziel: NAME|IP. Neue Ziele hier ergänzen.
TARGETS=(
  "google-dns|8.8.8.8"
  "cloudflare-dns|1.1.1.1"
)

# --- Konfiguration prüfen --------------------------------------------------
validate_config() {
  if [[ -z "$DB_USER" || -z "$DB_PASSWORD" ]]; then
    echo "FEHLER: DB_USER oder DB_PASSWORD fehlt." >&2
    return 1
  fi
  if [[ -z "$DB_NAME" ]]; then
    echo "FEHLER: DB_NAME fehlt (wird von Jenkins aus Version.txt erzeugt)." >&2
    return 1
  fi
  # Namen werden als SQL-Datenbankbezeichner verwendet: nur sichere Zeichen.
  if [[ ! "$DB_NAME" =~ ^[a-zA-Z][a-zA-Z0-9_]*$ ]]; then
    echo "FEHLER: Ungültiger Datenbankname: $DB_NAME" >&2
    return 1
  fi
  for number in "$CHECK_INTERVAL" "$MAX_RUNTIME_SECONDS"; do
    if [[ ! "$number" =~ ^[1-9][0-9]*$ ]]; then
      echo "FEHLER: CHECK_INTERVAL und MAX_RUNTIME_SECONDS müssen positive Ganzzahlen sein." >&2
      return 1
    fi
  done
  if [[ "$RUN_ONCE" != "0" && "$RUN_ONCE" != "1" ]]; then
    echo "FEHLER: RUN_ONCE muss 0 oder 1 sein." >&2
    return 1
  fi
}

# --- Datenbankzugriff -------------------------------------------------------
# MYSQL_PWD vermeidet ein Passwort als Kommandozeilenargument. Achtung:
# Umgebungsvariablen sind für berechtigte Docker-Nutzer weiterhin einsehbar.
db_query() {
  MYSQL_PWD="$DB_PASSWORD" mariadb \
    --protocol=TCP --host="$DB_HOST" --port="$DB_PORT" \
    --user="$DB_USER" --database="$DB_NAME" --batch --silent "$@"
}

# --- Deployment dokumentieren ----------------------------------------------
register_release() {
  # Ein Integrationstest speichert Messwerte, ist aber kein echtes Deployment.
  [[ "$RUN_ONCE" == "1" ]] && return 0

  if [[ ! "$NETWATCH_VERSION" =~ ^[0-9]+(\.[0-9]+){1,2}$ || \
        ! "$NETWATCH_BUILD" =~ ^[0-9]+$ || \
        ! "$NETWATCH_COMMIT" =~ ^[0-9a-fA-F]{7,64}$ ]]; then
    echo "FEHLER: Versions-, Build- oder Git-Information ungültig." >&2
    return 1
  fi

  # Die Jenkins-Buildnummer ist eindeutig: bei erneutem Ausrollen aktualisieren.
  db_query -e "INSERT INTO netwatch_release
    (version, build_number, git_commit, image_tag)
    VALUES ('$NETWATCH_VERSION', $NETWATCH_BUILD, '$NETWATCH_COMMIT',
            'netwatch:${NETWATCH_VERSION}-b${NETWATCH_BUILD}')
    ON DUPLICATE KEY UPDATE image_tag = VALUES(image_tag);"
  echo "Deployment: NetWatch v$NETWATCH_VERSION, Jenkins #$NETWATCH_BUILD, Git $NETWATCH_COMMIT"
}

# --- Einen kompletten Monitoring-Durchlauf ausführen ----------------------
monitor_cycle() {
  echo "[$(date '+%Y-%m-%d %H:%M:%S')] Prüfe Datenbank und Hosts ..."

  # Fail fast: Ist die Tabelle nicht vorhanden/erreichbar, keine Hosts prüfen.
  db_query -e 'SELECT 1 FROM monitoring_results LIMIT 0;' >/dev/null || {
    echo "FEHLER: Tabelle monitoring_results nicht erreichbar ($DB_NAME)." >&2
    return 1
  }

  # Alle Messwerte eines Durchlaufs gemeinsam in einer Transaktion speichern.
  local sql=$'START TRANSACTION;\n'
  local target name ip ping_output status response_time_ms

  for target in "${TARGETS[@]}"; do
    IFS='|' read -r name ip <<< "$target"
    # Die Werte werden in SQL eingesetzt; unerwartete Sonderzeichen ablehnen.
    if [[ ! "$name" =~ ^[a-zA-Z0-9_-]+$ || ! "$ip" =~ ^[0-9a-fA-F:.]+$ ]]; then
      echo "FEHLER: Ungueltiges Monitoring-Ziel: $target" >&2
      return 1
    fi

    response_time_ms=NULL  # SQL-NULL, wenn Ping fehlschlägt/keine Zeit liefert.
    if ping_output="$(ping -n -c 1 -W 2 "$ip" 2>/dev/null)"; then
      status=ONLINE
      # Aus einer Ausgabe wie "time=12.34 ms" nur die Zahl übernehmen.
      if [[ "$ping_output" =~ time=([0-9]+([.][0-9]+)?) ]]; then
        response_time_ms="${BASH_REMATCH[1]}"
      fi
    else
      status=OFFLINE
    fi

    if [[ "$response_time_ms" == NULL ]]; then
      echo "  $name ($ip): $status, Antwortzeit: n/a"
    else
      echo "  $name ($ip): $status, Antwortzeit: ${response_time_ms} ms"
    fi

    sql+="INSERT INTO monitoring_results
      (name, ip_address, status, response_time_ms)
      VALUES ('$name', '$ip', '$status', $response_time_ms);"$'\n'
  done

  sql+=$'COMMIT;\n'
  db_query <<< "$sql" || {
    echo 'FEHLER: Messwerte konnten nicht gespeichert werden.' >&2
    return 1
  }
  echo 'Messwerte in MariaDB gespeichert.'
}

# --- Ablauf steuern ---------------------------------------------------------
run_monitoring() {
  local start_seconds=$SECONDS
  local registered=0
  local elapsed remaining sleep_seconds

  while true; do
    monitor_cycle

    # Nur einmal je Containerstart dokumentieren, nicht bei jedem Ping.
    if (( registered == 0 )); then
      register_release
      registered=1
    fi
    [[ "$RUN_ONCE" == "1" ]] && break

    # Die letzte Pause ggf. verkürzen, damit die Laufzeitgrenze gilt.
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

  echo "NetWatch regulär beendet (Laufzeitgrenze: ${MAX_RUNTIME_SECONDS}s)."
}

validate_config
run_monitoring
