#!/usr/bin/env bash
# Automatischer Funktionstest fuer NetWatch, ohne produktive Datenbank.
# Die Kommandos ping und mariadb werden nur waehrend dieses Tests simuliert.
set -Eeuo pipefail

cd -- "$(dirname -- "${BASH_SOURCE[0]}")"

TMP_DIR="$(mktemp -d)"
trap 'rm -rf -- "$TMP_DIR"' EXIT
MOCK_DIR="$TMP_DIR/mock-bin"
mkdir -p "$MOCK_DIR"
MOCK_SQL_LOG="$TMP_DIR/sql.log"
export MOCK_SQL_LOG

# Ping-Mock: Im gemischten Fall ist nur Google erreichbar.
cat > "$MOCK_DIR/ping" <<'MOCKPING'
#!/usr/bin/env bash
set -euo pipefail
ip=''
for argument in "$@"; do ip="$argument"; done
case "${MOCK_PING_MODE:-online}" in
  online) ;;
  offline) exit 1 ;;
  mixed) [[ "$ip" == '8.8.8.8' ]] || exit 1 ;;
  *) exit 2 ;;
esac
printf '64 bytes from %s: icmp_seq=1 ttl=55 time=12.34 ms\n' "$ip"
MOCKPING

# MariaDB-Mock: nimmt SQL entgegen, speichert es in einer lokalen Testdatei.
# Bei MOCK_DB_FAIL=1 simuliert er einen DB-Ausfall.
cat > "$MOCK_DIR/mariadb" <<'MOCKDB'
#!/usr/bin/env bash
set -euo pipefail
[[ "${MOCK_DB_FAIL:-0}" == '0' ]] || exit 1
for argument in "$@"; do
  [[ "$argument" == '-e' ]] && exit 0
 done
cat >> "${MOCK_SQL_LOG:?}"
MOCKDB
chmod +x "$MOCK_DIR/ping" "$MOCK_DIR/mariadb"

export PATH="$MOCK_DIR:$PATH"
export DB_USER='testuser' DB_PASSWORD='testpassword' DB_NAME='netwatch_test'
export RUN_ONCE=1 CHECK_INTERVAL=1 MAX_RUNTIME_SECONDS=5

passed=0
pass() {
  passed=$((passed + 1))
  printf 'TEST %d OK: %s\n' "$passed" "$1"
}
fail() {
  printf 'TEST FEHLGESCHLAGEN: %s\n' "$1" >&2
  exit 1
}
assert_contains() {
  local expected="$1" file="$2"
  grep -Fq -- "$expected" "$file" || fail "Fehlt in $file: $expected"
}

run_success_case() {
  local description="$1" mode="$2" google_status="$3" cloudflare_status="$4"
  : > "$MOCK_SQL_LOG"
  MOCK_PING_MODE="$mode" bash ./netwatch.sh > "$TMP_DIR/output.log" 2>&1 || {
    cat "$TMP_DIR/output.log" >&2
    fail "$description: NetWatch hat einen Fehler gemeldet"
  }
  assert_contains "google-dns (8.8.8.8): $google_status" "$TMP_DIR/output.log"
  assert_contains "cloudflare-dns (1.1.1.1): $cloudflare_status" "$TMP_DIR/output.log"
  assert_contains "('google-dns', '8.8.8.8', '$google_status'," "$MOCK_SQL_LOG"
  assert_contains "('cloudflare-dns', '1.1.1.1', '$cloudflare_status'," "$MOCK_SQL_LOG"
  [[ "$(grep -c 'INSERT INTO monitoring_results' "$MOCK_SQL_LOG")" == '2' ]] || fail "$description: Anzahl SQL-INSERTs stimmt nicht"
  if [[ "$google_status" == ONLINE ]]; then
    assert_contains "('google-dns', '8.8.8.8', 'ONLINE', 12.34)" "$MOCK_SQL_LOG"
  else
    assert_contains "('google-dns', '8.8.8.8', 'OFFLINE', NULL)" "$MOCK_SQL_LOG"
  fi
  if [[ "$cloudflare_status" == ONLINE ]]; then
    assert_contains "('cloudflare-dns', '1.1.1.1', 'ONLINE', 12.34)" "$MOCK_SQL_LOG"
  else
    assert_contains "('cloudflare-dns', '1.1.1.1', 'OFFLINE', NULL)" "$MOCK_SQL_LOG"
  fi
  # RUN_ONCE=1 soll keinen Deployment-Eintrag erzeugen.
  if grep -Fq 'netwatch_release' "$MOCK_SQL_LOG"; then
    fail "$description: Ein Test hat einen Deployment-Eintrag erzeugt"
  fi
  pass "$description"
}

run_failure_case() {
  local description="$1" expected_message="$2"
  shift 2
  : > "$MOCK_SQL_LOG"
  if env "$@" bash ./netwatch.sh > "$TMP_DIR/output.log" 2>&1; then
    fail "$description: Fehler wurde nicht erkannt"
  fi
  assert_contains "$expected_message" "$TMP_DIR/output.log"
  pass "$description"
}

run_success_case 'ONLINE: zwei erreichbare Hosts und SQL-Messwerte' online ONLINE ONLINE
run_success_case 'OFFLINE: zwei unerreichbare Hosts und SQL-NULL' offline OFFLINE OFFLINE
run_success_case 'GEMISCHT: ein Host online, einer offline' mixed ONLINE OFFLINE
run_failure_case 'Negativ: DB-Passwort fehlt' 'DB_USER oder DB_PASSWORD fehlt' DB_PASSWORD=
run_failure_case 'Negativ: ungueltiger Datenbankname' 'Ungültiger Datenbankname' DB_NAME=ungueltig-name
run_failure_case 'Negativ: Datenbank nicht erreichbar' 'Tabelle monitoring_results nicht erreichbar' MOCK_DB_FAIL=1

printf 'Alle %d Funktionstests bestanden.\n' "$passed"
