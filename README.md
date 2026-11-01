# NetWatch

Kleine Bash-Anwendung: Ping-Ziele prüfen und Ergebnisse in MariaDB speichern.

## Voraussetzungen

- Bestehender MariaDB-Container `netwatch-db` im Docker-Netzwerk `netwatch-net`.
- MariaDB-Datenbank `netwatch` mit Tabelle `monitoring_results` und den Spalten:
  - `id`, `name`, `ip_address`, `checked_at`, `status`, `response_time_ms`
  - `checked_at` hat den Default `CURRENT_TIMESTAMP`.
- Die DB-Credentials `DB_USER` und `DB_PASSWORD` werden zur Laufzeit gesetzt.

## Docker-Image bauen

```bash
docker build -t netwatch:local .
```

## Erster Test (genau ein Messdurchlauf)

Auf dem Docker-Host:

```bash
read -rsp 'DB-Passwort: ' DB_PASSWORD; echo
export DB_PASSWORD
docker run --rm --network netwatch-net \
  -e DB_USER=admin -e DB_PASSWORD -e RUN_ONCE=1 \
  netwatch:local
unset DB_PASSWORD
```

**Sicherheit:** Umgebungsvariablen sind für andere Benutzer mit ausreichenden Docker-/Systemrechten einsehbar. Zugangsdaten nicht in Git oder in dauerhaft gespeicherte Klartextdateien legen. Das spätere Deployment übernimmt Jenkins mit Credentials-ID `1`.

## Laufender Betrieb

Ohne `RUN_ONCE=1` kontrolliert das Skript alle `CHECK_INTERVAL` Sekunden (Standard: 60). Ein späteres Jenkins-Deployment erzeugt einen dauerhaften Container im Netzwerk `netwatch-net`.

## Zielsysteme erweitern

Weitere Einträge im Array `TARGETS` in `netwatch.sh` anlegen, Format `name|ip-oder-hostname` (einfache ASCII-Namen ohne Leerzeichen).

## DB-Konfiguration

- `DB_HOST` (Standard: `netwatch-db`)
- `DB_PORT` (Standard: `3306`)
- `DB_NAME` (Standard: `netwatch`)
- `DB_USER` (Pflicht)
- `DB_PASSWORD` (Pflicht)
- `CHECK_INTERVAL` (Standard: `60`)
- `RUN_ONCE` (`1`: einmal ausführen, ansonsten Endlosschleife)

**Hinweis:** `OFFLINE` bedeutet lediglich „keine Ping-Antwort“ und nicht zwingend, dass der Zielhost ausgeschaltet ist.
