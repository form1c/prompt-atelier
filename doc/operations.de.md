[English](operations.md) · **Deutsch**

# Prompt Atelier: Betriebshandbuch

| | |
|---|---|
| **Fassung** | 2.2 |
| **Stand** | 2026-09-03 |
| **Beschreibt** | Prompt Atelier 1.0.1 |
| **Zielgruppe** | Betreiber im laufenden Betrieb |
| **Nicht enthalten** | Der durchgehende Einrichtungsweg. Siehe `installation.de.md`. Arbeit am Quelltext. Siehe `development.de.md` |

Dieses Handbuch ist ein Nachschlagewerk. Es beschreibt jede Einstellung, jedes Skript und jede Meldung einzeln. Der zusammenhängende Weg von der Voraussetzung bis zum laufenden Betrieb steht in `installation.de.md`.

---

## Inhalt

1. [Verzeichnisaufbau](#1-verzeichnisaufbau)
2. [Konfigurationsreferenz](#2-konfigurationsreferenz)
3. [Skriptreferenz](#3-skriptreferenz)
4. [Wiederkehrende Aufgaben](#4-wiederkehrende-aufgaben)
5. [Meldungen und Störungen](#5-meldungen-und-störungen)
6. [Protokolle](#6-protokolle)

---

## 1. Verzeichnisaufbau

| Verzeichnis | Inhalt | Beim Update |
|---|---|---|
| `app/` | Anwendung, Bibliotheken, gebaute Oberfläche | wird ersetzt |
| `config/` | `config.yml` und `config.example.yml` | bleibt unverändert |
| `data/` | Datenbank, Sicherungen, Protokolle | bleibt unverändert |
| `scripts/` | Betriebsskripte | wird ersetzt |
| `doc/` | Anleitung, Betriebshandbuch, Entwicklerhandbuch sowie unter `doc/examples/` die Vorlagen für Reverse-Proxy-Konfigurationen | wird ersetzt |
| `README.md`, `LICENSE` | Kurzüberblick und Lizenztext | werden ersetzt |
| `tools/` | Hilfsprogramme, unter Windows `nssm.exe` | bleibt unverändert |

Alle Pfade werden relativ zum Installationsverzeichnis aufgelöst. Das Verzeichnis kann verschoben werden.

---

## 2. Konfigurationsreferenz

Sämtliche Einstellungen liegen in `config/config.yml`. Fehlt ein Wert, gilt der Standardwert aus `config/config.example.yml`. Ein ungültiger Wert oder ein unbekannter Schlüsselname verhindert den Start und wird in der Startmeldung benannt.

### 2.1 `server`

| Schlüssel | Standard | Bedeutung |
|---|---|---|
| `host` | `127.0.0.1` | Adresse, auf der die Anwendung Verbindungen entgegennimmt. `0.0.0.0` nur hinter einem Reverse Proxy |
| `port` | `9292` | TCP-Port, 1 bis 65535 |
| `base_url` | `http://localhost:9292` | Vollständige Adresse, unter der die Instanz erreichbar ist |
| `trusted_proxies` | `[]` | Liste der Adressen oder Netze, deren Weiterleitungsangaben ausgewertet werden |

### 2.2 `database`

| Schlüssel | Standard | Bedeutung |
|---|---|---|
| `path` | `data/promptatelier.db` | Pfad der Datenbankdatei |
| `wal` | `true` | Write-Ahead-Logging. Voraussetzung für konsistente Sicherungen im laufenden Betrieb |

### 2.3 `session`

| Schlüssel | Standard | Bedeutung |
|---|---|---|
| `idle_timeout_days` | `14` | Zeitraum ohne Aktivität, nach dem eine Sitzung endet |
| `absolute_timeout_days` | `90` | Höchstdauer einer Sitzung unabhängig von der Aktivität |

### 2.4 `security`

| Schlüssel | Standard | Bedeutung |
|---|---|---|
| `argon2.memory_mib` | `64` | Speicherbedarf je Passwortprüfung |
| `argon2.iterations` | `3` | Anzahl der Durchläufe |
| `argon2.parallelism` | `1` | Anzahl paralleler Bahnen |
| `login_attempts_per_account` | `5` | Fehlversuche je Konto innerhalb des Sperrfensters |
| `login_attempts_per_ip` | `20` | Fehlversuche je Absenderadresse innerhalb des Sperrfensters |
| `lockout_minutes` | `15` | Länge des Sperrfensters |
| `force_https` | `false` | Leitet HTTP auf HTTPS um und setzt das Cookie-Merkmal `Secure`. Über HTTPS trägt das Cookie `Secure` ohnehin. Bei Aufrufen über `localhost`, `127.0.0.1` und `::1` bleiben Umleitung und Merkmal aus |
| `registration` | `off` | Selbstregistrierung: `off`, `approval` oder `open` |
| `registrations_per_hour` | `5` | Höchstzahl neuer Konten je Absenderadresse und Stunde |

Eine Erhöhung der Argon2-Werte verlängert jede Anmeldung. Änderungen wirken nur auf neu vergebene Passwörter.

> **Achtung:** `registration`, `registrations_per_hour`, `login_attempts_per_account`, `login_attempts_per_ip` und `lockout_minutes` sind zusätzlich im Verwaltungsbereich einstellbar. Wurde einer dieser Werte dort einmal gespeichert, hat der gespeicherte Wert dauerhaft Vorrang vor der Datei. Eine spätere Änderung derselben Zeile bleibt dann wirkungslos.

### 2.5 `backup`

| Schlüssel | Standard | Bedeutung |
|---|---|---|
| `keep` | `14` | Anzahl aufbewahrter Sicherungen. Ältere werden beim nächsten Lauf entfernt |

Vor Schemaänderungen erzeugte Sicherungen werden dabei nicht mitgezählt.

### 2.6 `retention`

| Schlüssel | Standard | Bedeutung |
|---|---|---|
| `revisions_per_prompt` | `50` | Aufbewahrte Revisionen je Prompt |
| `revisions_min_days` | `90` | Mindestaufbewahrung von Revisionen in Tagen |
| `trash_days` | `30` | Aufbewahrung gelöschter Prompts im Papierkorb |
| `audit_months` | `12` | Aufbewahrung der Prüfprotokolleinträge in Monaten |
| `audit_max_entries` | `200000` | Höchstzahl der Prüfprotokolleinträge |
| `login_attempts_days` | `7` | Aufbewahrung protokollierter Anmeldeversuche |

Diese Werte sind zusätzlich im Verwaltungsbereich der Anwendung einstellbar und wirken dort sofort. Ein dort gespeicherter Wert hat dauerhaft Vorrang vor der Datei.

### 2.7 `logging`

| Schlüssel | Standard | Bedeutung |
|---|---|---|
| `level` | `info` | `debug`, `info`, `warn` oder `error` |
| `path` | `data/logs` | Verzeichnis der Protokolldateien |
| `rotate_mb` | `20` | Größe, ab der eine Protokolldatei gewechselt wird |
| `keep_files` | `5` | Anzahl aufbewahrter Protokolldateien |

### 2.8 Sprache der Instanz

Anders als die vorangehenden Abschnitte beschreibt dieser keinen Block, sondern einen einzelnen Schlüssel auf der **obersten Ebene** der Datei:

```yaml
locale: "de"
```

| Schlüssel | Standard | Bedeutung |
|---|---|---|
| `locale` | leer | Sprache der Oberfläche für die gesamte Instanz. Leer bedeutet, dass die Spracheinstellung des Browsers gilt |

Ausgeliefert werden fünf Sprachen:

| Kennung | Sprache |
|---|---|
| `de` | Deutsch |
| `en` | Englisch |
| `fr` | Französisch |
| `it` | Italienisch |
| `es` | Spanisch |

Die Angabe legt die Voreinstellung der Instanz fest. Benutzer können im Profil eine abweichende Sprache wählen.

> **Hinweis:** Geprüft wird beim Start nur die **Form** der Kennung, etwa `pt-BR`. Eine formal gültige Kennung ohne zugehörige Sprachdatei wird angenommen, die Oberfläche erscheint dann jedoch auf Englisch.

### 2.9 Dateirechte

`config/config.yml` wird mit den Rechten `0600` angelegt. Bei weiter gefassten Rechten gibt die Anwendung beim Start einen Hinweis aus und startet dennoch, da unter Windows keine Entsprechung besteht.

Die Datei enthält kein Sitzungsgeheimnis. Schützenswert ist `server.trusted_proxies`: Wer diese Liste ändern kann, kann die Begrenzung der Anmeldeversuche aufheben und beliebige Adressen in das Prüfprotokoll eintragen lassen.

---

## 3. Skriptreferenz

Jedes Skript liegt unter `scripts/` als `.sh` und als `.bat` vor. Die Startdateien enthalten keine eigene Logik. Die folgenden Angaben gelten für beide Formen. Der Rückgabewert `0` bedeutet erfolgreiche Ausführung.

Alle Skripte arbeiten auf der Installation, in der sie liegen, unabhängig vom aktuellen Arbeitsverzeichnis.

> **Achtung:** Die Schreibweise der Werte ist nicht einheitlich. `install` und `measure` erwarten sie mit Gleichheitszeichen, `seed_demo` mit Leerzeichen. Mit Ausnahme von `measure` werden unbekannte Schalter ohne Meldung übergangen.

### 3.1 `check_environment`

Prüft die Voraussetzungen und nennt zu jeder fehlenden den Installationsbefehl für das erkannte System.

| Schalter | Wirkung |
|---|---|
| ohne | Prüfumfang richtet sich nach der erkannten Installationsform |
| `--operation-only` | nur die für den Betrieb erforderlichen Bestandteile |
| `--all` | zusätzlich die Bauwerkzeuge Node.js und npm |
| `--skip-gems` | ohne Prüfung der Ruby-Bibliotheken |
| `--no-heading` | ohne Überschrift, für den Aufruf aus anderen Skripten |

### 3.2 `install`

Erstinstallation in sieben Schritten.

| Schalter | Wirkung |
|---|---|
| `--port=<zahl>` | Port festlegen |
| `--mode=portable` \| `--mode=service` | Betriebsart festlegen |
| `--admin-name=<name>` | Name des ersten Kontos |
| `--admin-email=<adresse>` | Adresse des ersten Kontos |
| `--admin-password=<passwort>` | Passwort des ersten Kontos |

Werden alle Angaben übergeben, läuft die Installation ohne Rückfrage. Ohne Terminal und ohne vollständige Angaben benennt das Skript die fehlende Angabe und bricht ab.

Bei wiederholter Ausführung bleiben vorhandene Konfiguration, Datenbank und Verwaltungskonto unverändert.

### 3.3 `start_portable`

Startet die Anwendung im Vordergrund. Strg+C beendet sie und erzeugt dabei eine Sicherung.

| Schalter | Wirkung |
|---|---|
| `--no-backup` | ohne Sicherung beim Beenden |

### 3.4 `service_install` und `service_uninstall`

Richtet die Anwendung als Dienst ein oder entfernt sie. Konfiguration und Daten bleiben in beiden Fällen erhalten.

| Schalter | Wirkung |
|---|---|
| ohne | Linux: Benutzerdienst. Windows: Dienst über NSSM |
| `--system` | Linux: Systemdienst, erhöhte Rechte erforderlich |

Der Systemdienst läuft unter dem Konto, dem das Installationsverzeichnis gehört, nicht als `root`. Beim Entfernen eines Benutzerdienstes bleibt `loginctl enable-linger` gesetzt. Das Skript weist darauf hin und nennt den Befehl, der es zurücknimmt.

### 3.5 `migrate`

Bringt das Datenbankschema auf den Stand der Anwendung und erzeugt zuvor eine Sicherung.

| Schalter | Wirkung |
|---|---|
| `--status` | gibt die ausstehenden Schritte aus, ohne Änderungen vorzunehmen |

### 3.6 `backup`

Erzeugt eine konsistente Sicherung im laufenden Betrieb unter `data/backups/`.

| Schalter | Wirkung |
|---|---|
| `--no-rotate` | ältere Sicherungen bleiben erhalten |

### 3.7 `restore`

Spielt eine Sicherung zurück. Die Datei wird vollständig gelesen, bevor Daten überschrieben werden. Vor dem Ersetzen entsteht eine Sicherheitskopie des bisherigen Bestandes, deren Pfad am Ende genannt wird.

| Angabe | Wirkung |
|---|---|
| ohne Angabe | listet die jüngsten Sicherungen und nennt die Aufrufform |
| `<datei>` | Dateiname oder Pfad der Sicherung. Ein Name ohne Pfad wird gegen `data/backups/` aufgelöst, eine Sicherung von einem anderen Ort verlangt einen absoluten Pfad |
| `--yes` | ohne Rückfrage |

> **Achtung:** Die Anwendung ist vorher zu beenden. Das Skript prüft den konfigurierten Port und bricht ab, solange die Instanz antwortet.

### 3.8 `reset_admin_password`

Vergibt ein neues Passwort für ein Konto mit Instanzverwaltungsrechten. Alle Sitzungen des Kontos werden beendet, der Vorgang wird im Prüfprotokoll vermerkt, und das Konto muss bei der nächsten Anmeldung ein eigenes Passwort vergeben.

| Angabe | Wirkung |
|---|---|
| `<adresse>` | betroffenes Konto. Ohne Angabe nur zulässig, wenn genau ein Verwaltungskonto besteht |
| `--generate` | Passwort wird erzeugt und einmalig ausgegeben |

### 3.9 `seed_demo`

Legt Beispielinhalte im Workspace „Beispiele“ an. Dieses Skript verändert die vorhandene Installation und fragt vor der Ausführung nach.

| Angabe | Wirkung |
|---|---|
| `--remove` | entfernt die angelegten Inhalte anhand einer Markierung |
| `--yes` | ohne Rückfrage |
| `--email <adresse>` | Eigentümer der angelegten Prompts |
| `--workspace <name>` | abweichender Workspace-Name |

Inhalte außerhalb des angelegten Workspace werden nicht verändert. `--remove` erkennt auch umbenannte Beispielprompts und lässt eigene Inhalte im selben Workspace unberührt.

### 3.10 `package`

Erzeugt aus der vorhandenen Installation ein Archiv für ein Zielsystem ohne Internetzugang. Konfiguration und Daten werden nicht übernommen.

| Angabe | Wirkung |
|---|---|
| `[zielverzeichnis]` | Ablageort. Ohne Angabe neben dem Installationsverzeichnis |
| `--zip` | nur ZIP-Archiv statt ZIP und TAR |
| `--keep-tree` | das entpackte Zwischenverzeichnis bleibt stehen |

### 3.11 `export_all` und `import_all`

Übertragen eine gesamte Instanz auf eine neu aufgesetzte Instanz.

| Skript | Angabe | Wirkung |
|---|---|---|
| `export_all` | `[datei]` | Ohne Angabe wird eine Datei mit Zeitstempel unter `data/` erzeugt |
| `import_all` | `<datei>` | Einspielen. Weitere Schalter bestehen nicht |

Die Umzugsdatei enthält keine Passwörter und kein Prüfprotokoll. Jedes Konto erhält ein Einmalpasswort, das einmalig ausgegeben wird. `import_all` arbeitet ausschließlich auf einer Instanz ohne bestehende Konten und bricht andernfalls ab.

### 3.12 `measure`

Ermittelt Leistungswerte auf der Zielmaschine. Das Skript legt eine eigene Testinstallation an. Die vorhandene Installation bleibt unverändert. Unbekannte Schalter werden abgewiesen.

| Schalter | Standard | Wirkung |
|---|---|---|
| `--prompts=<zahl>` | 5000 | Umfang des Testbestands |
| `--runs=<zahl>` | 20 | Anzahl der Messläufe je Wert |
| `--dir=<pfad>` | neben der Installation | Ablageort der Testinstallation |
| `--keep` | aus | Testinstallation bleibt bestehen |
| `--serve` | aus | Testinstallation bleibt laufend erreichbar. Schließt `--keep` ein |
| `--no-load` | aus | ohne die Lastmessung |
| `--reseed` | aus | vorhandenen Testbestand verwerfen und neu aufbauen |

Der Bericht wird als Markdown-Datei unter `reports/measurement-<anzahl>.md` abgelegt, eine Ebene über der Testinstallation.

### 3.13 Nicht ausgelieferte Skripte

`build`, `start_development` und `run_tests` gehören zur Entwicklungsumgebung und sind in der Auslieferung nicht enthalten.

---

## 4. Wiederkehrende Aufgaben

| Aufgabe | Empfohlener Abstand |
|---|---|
| Entstehen der Sicherungen prüfen | monatlich |
| Wiederherstellung einer Sicherung erproben | halbjährlich |
| Plattenbelegung von `data/` prüfen | halbjährlich |
| Auf eine neue Fassung aktualisieren | nach Verfügbarkeit |

Papierkorb, Revisionen, Prüfprotokoll und protokollierte Anmeldeversuche werden anhand der Werte unter `retention` selbsttätig bereinigt. Der Aufräumlauf wird von der **ersten Anfrage eines Kalendertages** angestoßen und läuft höchstens einmal je Tag. Eine Instanz ohne Zugriffe räumt daher nicht auf, und ein fehlgeschlagener Lauf wird erst am Folgetag wiederholt.

### 4.1 Aktualisierung

1. Sicherung erzeugen: `scripts/backup.sh`
2. Dienst beenden
3. Alles ersetzen, was in Kapitel 1 als „wird ersetzt“ geführt ist: `app/`, `scripts/`, `doc/`, `README.md` und `LICENSE`
4. Schema aktualisieren: `scripts/migrate.sh`
5. Dienst starten
6. Zustandsendpunkt `/health` abfragen

### 4.2 Betriebsart wechseln

```bash
scripts/service_install.sh            # Dienst einrichten
scripts/service_uninstall.sh          # Dienst entfernen
scripts/start_portable.sh             # portabel starten
```

Ein Wechsel ist jederzeit möglich. Konfiguration und Daten bleiben unberührt.

---

## 5. Meldungen und Störungen

### 5.1 Die Anwendung startet nicht

| Meldung | Ursache | Vorgehen |
|---|---|---|
| Nennt einen Konfigurationsschlüssel und einen erwarteten Wertebereich | ungültiger Wert in `config.yml` | Wert korrigieren |
| Nennt einen unbekannten Schlüssel | Schreibfehler im Schlüsselnamen | Schreibweise gegen `config.example.yml` prüfen |
| `EADDRINUSE` | Port belegt | anderen Port konfigurieren oder belegenden Prozess beenden |
| Schemastand zu alt | ausstehende Schemaschritte | `scripts/migrate.sh` |
| Schemastand zu neu | Datenbank stammt aus einer neueren Fassung | passende Anwendungsfassung installieren |
| Konfigurationsdatei fehlt | Installation unvollständig | `scripts/install.sh` |

### 5.2 Die Anwendung ist nicht erreichbar

Im Auslieferungszustand nimmt die Anwendung Verbindungen ausschließlich über `127.0.0.1` entgegen. Für den Zugriff aus dem Netz siehe `installation.de.md`, Kapitel 8.

### 5.3 Anmeldung nicht möglich

| Beobachtung | Ursache | Vorgehen |
|---|---|---|
| Ein Konto ist gesperrt | Anmeldegrenze überschritten | Sperrfenster abwarten oder Konto im Verwaltungsbereich entsperren |
| Alle Benutzer nach einer Wiederherstellung abgemeldet | Sitzungen werden in der Datenbank geführt | erneute Anmeldung |
| Kein Verwaltungszugang mehr vorhanden | Passwort unbekannt oder Konto gesperrt | `scripts/reset_admin_password.sh` |

Ein Zurücksetzen des Passworts per E-Mail besteht nicht. Der Notfallzugang setzt Zugriff auf den Rechner und auf das Installationsverzeichnis voraus.

### 5.4 Fehlermeldung mit Kennung

Bei serverseitigen Fehlern zeigt die Oberfläche eine allgemeine Meldung mit einer Kennung an. Pfade, Abfragen und Stapelspuren erscheinen ausschließlich im Protokoll. Über die Kennung lässt sich der zugehörige Eintrag auffinden.

---

## 6. Protokolle

| Protokoll | Ort | Inhalt |
|---|---|---|
| Anwendungsprotokoll | `data/logs/` | Fehler und Ereignisse mit Zeitstempel, Benutzerkennung und Anforderungskennung |
| Dienstprotokoll, Benutzerdienst | `journalctl --user -u promptatelier` | Ausgaben des Dienstes unter Linux |
| Dienstprotokoll, Systemdienst | `journalctl -u promptatelier` | für einen mit `--system` eingerichteten Dienst |
| Prüfprotokoll | Verwaltungsbereich der Anwendung | sicherheitsrelevante Vorgänge, über die Oberfläche nicht änderbar |

Umfang und Aufbewahrung des Anwendungsprotokolls werden über `logging` gesteuert, die des Prüfprotokolls über `retention`.
