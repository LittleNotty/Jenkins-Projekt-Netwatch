# NetWatch – Testnachweis (Bewertungsbogen Teil 7 und 8)

## Testaufbau

- Automatischer Pipeline-Schritt **Tests (Syntax und Funktion)**: `bash -n netwatch.sh`, `bash -n test.sh`, `bash test.sh`.
- `test.sh` simuliert ausschließlich `ping` und `mariadb` in einem temporären Verzeichnis. Dadurch werden weder echte Hosts kontaktiert noch produktive Datensätze verändert.
- Danach erstellt Jenkins erst das neue Docker-Image. Der bestehende MariaDB-Integrationstest und der Smoke-Test bleiben erhalten.
- Jede fehlgeschlagene `sh`-Ausführung stoppt die normale Pipeline, damit **kein Deployment** stattfindet.

## Testfälle: Lokal tatsächlich ausgeführt am 01.11.2026

| ID | Testfall | Soll | Ist (lokaler Testlauf) | Ergebnis |
| --- | --- | --- | --- | --- |
| T01 | Zwei Hosts erreichbar | Beide `ONLINE`, Antwortzeit und 2 SQL-INSERTs | Entsprechende Ausgaben, `12.34 ms`, 2 INSERTs | BESTANDEN |
| T02 | Zwei Hosts nicht erreichbar | Beide `OFFLINE`, Antwortzeit `NULL`, 2 INSERTs | Entsprechende Ausgaben und 2 INSERTs | BESTANDEN |
| T03 | Ein Host erreichbar, einer nicht | Einmal `ONLINE`, einmal `OFFLINE`, 2 INSERTs | Entsprechende Ausgaben und 2 INSERTs | BESTANDEN |
| T04 | DB-Passwort fehlt | NetWatch bricht mit Fehlercode ab | Fehler korrekt erkannt | BESTANDEN |
| T05 | Ungültiger DB-Name | NetWatch bricht mit Fehlercode ab | Fehler korrekt erkannt | BESTANDEN |
| T06 | Datenbank nicht erreichbar | NetWatch meldet DB-Fehler und bricht ab | Fehler korrekt erkannt | BESTANDEN |
| T07 | Bash-Syntax von `netwatch.sh` und `test.sh` | Kein Syntaxfehler | `bash -n` meldet keinen Fehler | BESTANDEN |

**Einschränkung:** Die INSERTs werden in T01–T03 von einem MariaDB-Mock entgegengenommen. Der bestehende Jenkins-Integrationstest überprüft zusätzlich den echten DB-Zugriff, wurde hier jedoch nicht auf deinem Server ausgeführt.

## Noch am echten Jenkins / im Browser nachweisen

| ID | Durchführung | Soll | Ist / Screenshot |
| --- | --- | --- | --- |
| T08 | Neues Jenkinsfile und `test.sh` nach GitHub pushen | Pipeline startet, Tests grün, Docker-Image und Deployment erfolgreich | Noch durchführen |
| T09 | **Vorübergehend** `exit 1` am Anfang von `test.sh` einfügen, committen und pushen | Teststage rot, Docker-Image und Deployment übersprungen; alter Container bleibt | Noch durchführen |
| T10 | Testfehler entfernen und erneut pushen | Pipeline wieder grün, neuer Container deployed | Noch durchführen |
| T11 | `netwatch.sh` auf https://www.shellcheck.net/ einfügen | ShellCheck-Ausgabe prüfen und dokumentieren | Noch durchführen |

**Wichtig:** Den absichtlichen Fehler nach T09 wieder rückgängig machen. Für T08–T11 keine Ergebnisse behaupten, bevor du die entsprechenden Jenkins-/Browser-Screenshots aufgenommen hast.

## ShellCheck (Webseite)

`https://www.shellcheck.net/` öffnen, kompletten Inhalt von `netwatch.sh` einfügen und Befunde bei Bedarf korrigieren. Screenshot der tatsächlichen Ausgabe sichern. ShellCheck.net konnte in der aktuellen Entwicklungsumgebung nicht interaktiv ausgeführt werden, daher wird kein Prüfergebnis erfunden.
