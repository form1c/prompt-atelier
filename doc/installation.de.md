[English](installation.md) · **Deutsch**

# Prompt Atelier: Installations- und Betriebsanleitung

| | |
|---|---|
| **Fassung** | 1.3 |
| **Stand** | 2026-09-03 |
| **Beschreibt** | Prompt Atelier 1.0.1 |
| **Zielgruppe** | Betreiber bei Einrichtung und Betrieb einer Installation |
| **Nicht enthalten** | Arbeit am Quelltext. Siehe `development.de.md` |

Diese Anleitung führt vollständig von den Voraussetzungen bis zum laufenden Betrieb. Für das Nachschlagen einzelner Aufgaben im laufenden Betrieb ist das `operations.de.md` vorgesehen.

---

## Inhalt

1. [Vorbereitung](#1-vorbereitung)
2. [Installation](#2-installation)
3. [Betriebsarten](#3-betriebsarten)
4. [Konfiguration](#4-konfiguration)
5. [Grundbegriffe der Anwendung](#5-grundbegriffe-der-anwendung)
6. [Datensicherung und Wiederherstellung](#6-datensicherung-und-wiederherstellung)
7. [Aktualisierung](#7-aktualisierung)
8. [Betrieb hinter einem Reverse Proxy](#8-betrieb-hinter-einem-reverse-proxy)
9. [Störungsbehebung](#9-störungsbehebung)
10. [Skriptübersicht](#10-skriptübersicht)
11. [Sicherheitsmerkmale](#11-sicherheitsmerkmale)
12. [Mengenbegrenzungen](#12-mengenbegrenzungen)

---

## 1. Vorbereitung

### 1.1 Dimensionierung

Die Anwendung ist für Instanzen mit bis zu 50 Benutzern und 20.000 Prompts ausgelegt. Sie benötigt keinen Datenbankserver. Die Daten liegen in einer einzelnen SQLite-Datei.

Die Leistungsfähigkeit der Zielmaschine lässt sich vor der Inbetriebnahme prüfen:

```bash
scripts/measure.sh
```

Das Skript legt eine eigene Testinstallation mit eigenem Verzeichnis, eigener Datenbank und eigenem Port an und schreibt einen Bericht. Die vorhandene Installation bleibt unverändert.

### 1.2 Das Archiv

Veröffentlicht wird je Fassung ein plattformunabhängiges Archiv, als `.tar.gz` und als `.zip`:

```
promptatelier-1.0.1-universal.tar.gz
promptatelier-1.0.1-universal.zip
```

Es enthält die Anwendung mit fertig gebauter Oberfläche, jedoch **keine Ruby-Bibliotheken**. Diese bezieht das Installationsskript beim ersten Lauf aus dem Internet, anhand der mitgelieferten Sperrdatei `Gemfile.lock`.

**Der Verzicht auf ein Archiv mit vorkompilierten Bibliotheken ist beabsichtigt.** Vorkompilierte Bibliotheken sind Binärdateien, die auf einem fremden Rechner erzeugt wurden. Wer sie ausführt, muss dem Erzeuger vertrauen. Werden die Bibliotheken stattdessen auf der Zielmaschine bezogen, stammen sie aus der offiziellen Bezugsquelle und lassen sich gegen die Sperrdatei prüfen.

Für die Zielmaschine ist damit ein Internetzugang erforderlich. Für Maschinen ohne Internetzugang siehe [Abschnitt 1.4](#14-installation-ohne-internetzugang).

> **Hinweis:** Unter Windows ist das `.zip`-Archiv zu verwenden.

### 1.3 Voraussetzungen prüfen

```bash
scripts/check_environment.sh --operation-only     # Linux
scripts\check_environment.bat --operation-only    # Windows
```

Das Skript prüft Ruby, Bundler und die Ruby-Bibliotheken und meldet jede fehlende Voraussetzung zusammen mit dem passenden Installationsbefehl für das erkannte System. Gelb markierte Hinweise beeinträchtigen den Betrieb nicht. Nur rot markierte Fehler verhindern ihn.

Plattenplatz, Arbeitsspeicher und die Belegung des vorgesehenen Ports prüft das Skript **nicht**. Diese drei Angaben sind selbst zu prüfen. Ein belegter Port fällt erst im letzten Schritt der Installation auf, dort jedoch mit eindeutiger Meldung.

| Umgebung | Anforderung |
|---|---|
| Linux | Ruby 3.3 oder neuer, mit Entwicklungsdateien und Übersetzer |
| Windows | Ruby 3.3 oder neuer, installiert als RubyInstaller mit DevKit |
| Beide | Bundler, 500 MB Plattenplatz, 1 GB Arbeitsspeicher, ein freier TCP-Port |

**Bundler gehört nicht immer zu Ruby.** RubyInstaller bringt es mit. Unter Debian und Ubuntu tut `ruby-full` das nicht, und die Installation bricht im ersten Schritt mit „Bundler is not present" ab. Auf Debian 13 gemessen:

```bash
sudo apt install -y ruby-full ruby-dev build-essential curl
sudo gem install bundler -v 4.0.11
```

Die Fassung ist die in `app/Gemfile.lock` genannte. Auf diesem Weg liegt das Programm in einem Verzeichnis, das sowohl im Suchpfad des gewöhnlichen Benutzers als auch in dem von `root` liegt. Das ist wichtig, sobald die Anwendung später als Systemdienst läuft. Das Distributionspaket `ruby-bundler` führt eine ältere Fassung und lässt Bundler sich bei jeder Installation selbst aktualisieren.

Unter Windows ist DevKit erforderlich, weil mehrere Bibliotheken bei der Installation kompiliert werden. Ohne DevKit bricht die Installation im zweiten Schritt mit einer Compiler-Meldung ab.

Node.js wird für den Betrieb nicht benötigt. Es dient ausschließlich dem Bauen der Oberfläche, die in der Auslieferung bereits gebaut enthalten ist.

### 1.4 Installation ohne Internetzugang

Ein Archiv einschließlich der Bibliotheken lässt sich selbst erzeugen. Dafür wird eine Maschine **derselben Art** mit Internetzugang benötigt, also dasselbe Betriebssystem und dieselbe Ruby-Reihe.

1. Auf der verbundenen Maschine wie gewohnt installieren:

   ```bash
   scripts/install.sh
   ```

2. Aus dieser Installation ein Archiv erzeugen:

   ```bash
   scripts/package.sh /pfad/zum/ablageort
   ```

3. Das erzeugte Archiv auf die Zielmaschine übertragen, entpacken und dort `scripts/install.sh` ausführen.

Das erzeugte Archiv enthält die Bibliotheken und benötigt auf der Zielmaschine keinen Internetzugang. **Konfiguration und Daten der Ausgangsinstallation werden nicht übernommen.** Die Zielmaschine fragt bei der Installation nach einem eigenen Verwaltungskonto.

Der Name des erzeugten Archivs nennt Plattform und Ruby-Reihe, etwa `promptatelier-1.0.1-x86_64-linux-gnu-ruby3.3.0.tar.gz`. Es ist ausschließlich für Maschinen dieser Art verwendbar.

---

## 2. Installation

```bash
tar -xzf promptatelier-1.0.1-universal.tar.gz     # Linux
cd promptatelier-1.0.1-universal
scripts/install.sh
```

Unter Windows das ZIP-Archiv über den Explorer entpacken und im entpackten Verzeichnis aufrufen:

```
scripts\install.bat
```

Das Skript führt sieben Schritte aus:

| Schritt | Vorgang |
|---|---|
| 1 | Prüfung der Voraussetzungen. Fehlende Bestandteile werden mit Installationsbefehl benannt |
| 2 | Installation der Ruby-Bibliotheken, sofern sie nicht bereits vorliegen |
| 3 | Erzeugung von `config/config.yml` aus der Vorlage, mit Dateirechten `0600` |
| 4 | Anlage des Datenbankschemas |
| 5 | Anlage des ersten Benutzerkontos mit Verwaltungsrechten |
| 6 | Einrichtung der Betriebsart |
| 7 | Start der Instanz und Abfrage des Zustandsendpunkts |

Nach Abschluss wird die Adresse der Instanz ausgegeben.

### 2.1 Unbeaufsichtigte Installation

Werden alle erforderlichen Angaben als Schalter übergeben, läuft die Installation ohne Rückfrage:

```bash
scripts/install.sh \
  --port=9292 \
  --mode=portable \
  --admin-name="Anna Beispiel" \
  --admin-email=anna@example.test \
  --admin-password='ein-langes-passwort'
```

> **Achtung:** Die Werte sind mit Gleichheitszeichen anzugeben. Eine Schreibweise mit Leerzeichen wie `--port 9292` wird nicht ausgewertet. Die Installation verwendet dann den Standardwert. Siehe [Kapitel 10](#10-skriptübersicht).

Steht kein Terminal zur Verfügung und fehlt eine erforderliche Angabe, benennt das Skript die fehlende Angabe und bricht ab.

### 2.2 Wiederholte Ausführung

Das Installationsskript kann mehrfach ausgeführt werden. Es erkennt vorhandene Bestandteile und meldet sie. Eine vorhandene `config/config.yml` bleibt unverändert. Ein zweites Verwaltungskonto wird nicht angelegt. Schemaschritte werden nicht ausgeführt und Sicherungen nicht erzeugt.

---

## 3. Betriebsarten

Es stehen vier Betriebsarten zur Verfügung:

| Betriebsart | Einsatz | Automatischer Start | Erhöhte Rechte |
|---|---|---|---|
| Linux, portabel | Einzelplatz, Wechseldatenträger, Erprobung | nein | nein |
| Linux, Dienst | Dauerbetrieb auf einem Server | ja | nur für den Systemdienst |
| Windows, portabel | Einzelplatz, Erprobung | nein | nein |
| Windows, Dienst | Dauerbetrieb | ja | ja |

Im portablen Betrieb kann das gesamte Installationsverzeichnis verschoben, kopiert oder auf einem Wechseldatenträger abgelegt werden. Alle Pfade sind relativ aufgelöst.

```bash
scripts/start_portable.sh            # Start im Vordergrund, Strg+C beendet
scripts/service_install.sh           # Linux: Benutzerdienst
scripts/service_install.sh --system  # Linux: Systemdienst, erhöhte Rechte erforderlich
scripts/service_uninstall.sh         # Dienst entfernen, Daten bleiben erhalten
```

### 3.1 Linux-Dienste

Der Benutzerdienst ist die Vorgabe. Er benötigt keine Administratorrechte und genügt für eine Maschine mit einem Benutzer.

Bei seiner Einrichtung wird `loginctl enable-linger` gesetzt. Ohne diese Einstellung startet der Dienst erst mit der Anmeldung des Benutzers, nach einem Neustart des Servers also möglicherweise gar nicht. Ob der Aufruf erhöhte Rechte erfordert, hängt von der Maschine ab. Unter Debian 13 gelang er als gewöhnlicher Benutzer. Schlägt er fehl, wird der Dienst dennoch eingerichtet, die Einschränkung gemeldet und der nachzuholende Befehl ausgegeben.

**Beim Entfernen des Dienstes wird Linger nicht wieder abgeschaltet.** Es ist eine maschinenweite Einstellung, die von etwas anderem stammen kann. `service_uninstall` benennt sie deshalb, statt sie stillschweigend zurückzunehmen, und nennt den Befehl dazu:

```bash
loginctl disable-linger <benutzer>
```

Der Systemdienst wird mit `scripts/service_install.sh --system` eingerichtet und erfordert erhöhte Rechte.

> **Achtung:** Der Systemdienst läuft **unter dem Konto, dem das Installationsverzeichnis gehört**, nicht als `root`. Dieses Konto muss `config/` und `data/` schreiben können, und ein Dienst, der dort als `root` schreibt, hinterlässt Dateien, die der Eigentümer anschließend nicht mehr ersetzen kann. Wird die Installation einem anderen Konto übergeben, richten Sie den Dienst neu ein, statt die Einheitendatei zu bearbeiten.

### 3.2 Windows-Dienst

Für den Dienstbetrieb ist `tools\nssm.exe` erforderlich. Ein Ruby-Skript kann unter Windows nicht selbst ein Dienst sein, ein Wrapper meldet es als solchen an.

**NSSM ist nicht Teil des Archivs.** Es ist ein eigenständiges Programm unter eigener Lizenz und steht unter <https://nssm.cc/download> bereit. Laden Sie es herunter, entnehmen Sie `nssm.exe` dem Verzeichnis `win64` des Archivs und legen Sie die Datei im Verzeichnis `tools` der Installation ab.

Die Skripte sind gegen **NSSM 2.24** entwickelt worden, die auf jener Seite angebotene Freigabe. Andere Fassungen sind nicht geprüft. Die Seite bietet zusätzlich eine Vorabfassung an. Verwenden Sie die Freigabe.

> **Achtung:** Das Anlegen eines Dienstes erfordert Administratorrechte. Öffnen Sie das Startmenü, geben Sie `cmd` ein, wählen Sie **Als Administrator ausführen** und rufen Sie von dort `scripts\service_install.bat` auf. Ohne diese Rechte meldet der Wrapper keinen eigenen Fehler, der Dienst entsteht aber nicht, und das Skript weist darauf hin.

Ein Windows-Dienst überdauert das Verzeichnis, aus dem er eingerichtet wurde. Hat ein früherer Versuch einen hinterlassen, weist das Skript darauf hin und bittet um einen vorherigen Aufruf von `scripts\service_uninstall.bat`.

Der Dienst startet `scripts\lib\service_run.rb`, das seine Umgebung selbst setzt. Sobald er eingerichtet ist, schreibt er nach `data\logs\service.log`. Diese Datei enthält den Grund, wenn der Dienst besteht, aber nicht oben bleibt.

Fehlt die Datei, meldet das Installationsskript dies und gibt einen Befehl aus, mit dem sich stattdessen eine Aufgabe in der Aufgabenplanung anlegen lässt. Dieser Befehl ist von Hand in einer als Administrator gestarteten Eingabeaufforderung auszuführen.

Eine so angelegte Aufgabe startet die Anwendung beim Systemstart, jedoch nicht nach einem Absturz. Sie ersetzt einen Dienst damit nur teilweise.

---

## 4. Konfiguration

Die gesamte Konfiguration liegt in `config/config.yml`. Die Datei wird bei der Installation vollständig erzeugt.

### 4.1 Verhalten bei fehlerhaften Angaben

1. Fehlt ein Wert, gilt der Standardwert aus `config/config.example.yml`.
2. Ein ungültiger Wert verhindert den Start. Die Meldung nennt den Schlüssel und den erwarteten Wertebereich.
3. Ein unbekannter Schlüsselname verhindert den Start ebenfalls. Ein Schreibfehler wird damit sichtbar, statt wirkungslos zu bleiben.

### 4.2 Zuständigkeit der Einstellungen

| Art | Beispiele | Ort | Wirksam |
|---|---|---|---|
| Betriebswerte | Adresse, Port, Pfade, vertraute Proxys, HTTPS-Erzwingung, Protokollierung | ausschließlich `config/config.yml` | nach dem nächsten Start |
| Produktwerte | Selbstregistrierung, Anmeldegrenzen, Sperrdauer, Aufbewahrungsfristen | `config/config.yml` **und** Verwaltungsbereich | im Verwaltungsbereich sofort |

> **Achtung:** Die elf Produktwerte bestehen an beiden Orten, und die beiden Orte sind nicht getrennt. Wurde ein Wert im Verwaltungsbereich einmal gespeichert, hat der gespeicherte Wert dauerhaft Vorrang. Jede spätere Änderung derselben Zeile in `config/config.yml` bleibt dann wirkungslos, auch nach einem Neustart.

Der Verwaltungsbereich weist zu jedem Wert aus, ob er aus der Datei stammt oder gespeichert wurde. Ein gespeicherter Wert lässt sich dort ändern, aber nicht auf den Dateiwert zurücksetzen. Wer die Datei als führende Quelle behalten will, ändert diese Werte nicht im Verwaltungsbereich.

Ein Neustart über die Oberfläche wird nicht angeboten. Im portablen Betrieb würde die Anwendung dadurch beendet, ohne erneut zu starten.

### 4.3 Dateirechte

`config/config.yml` wird mit den Rechten `0600` angelegt. Die Datei enthält die Liste der vertrauenswürdigen Proxys. Wer sie ändern kann, kann die Begrenzung der Anmeldeversuche aufheben und beliebige Adressen in das Prüfprotokoll eintragen lassen.

Sind die Rechte weiter gefasst, gibt die Anwendung beim Start einen Hinweis aus und startet dennoch. Unter Windows besteht keine Entsprechung zu diesen Rechten.

Die Datei enthält kein Sitzungsgeheimnis. Sitzungen werden über ein Zufallstoken geführt, von dem die Datenbank nur den Hashwert speichert. Um einen Benutzer auszuschließen, ist dessen Konto im Verwaltungsbereich zu sperren. Die zugehörigen Sitzungen enden damit sofort.

### 4.4 Selbstregistrierung

| Wert | Verhalten |
|---|---|
| `off` | Konten werden ausschließlich im Verwaltungsbereich angelegt. Auslieferungszustand |
| `approval` | Benutzer können sich eintragen und werden anschließend vom Instanz-Administrator freigeschaltet |
| `open` | Benutzer können sich eintragen und sind sofort angemeldet |

---

## 5. Grundbegriffe der Anwendung

### 5.1 Prompt

Ein Text mit Titel, Beschreibung, Schlagworten und Sichtbarkeit. Eine gesonderte Objektart für Vorlagen besteht nicht: Enthält der Text Platzhalter, wirkt der Prompt als Vorlage.

### 5.2 Variable

Ein Platzhalter in doppelten geschweiften Klammern erzeugt ein Formularfeld. Je Variable lassen sich Beschriftung, Standardwert, Pflichtangabe und Art (Textzeile, Mehrzeiler, Auswahl, Zahl) festlegen.

Zulässig sind Unicode-Buchstaben, Ziffern und der Unterstrich, höchstens 40 Zeichen. Das erste Zeichen muss ein Buchstabe sein. Zeichenfolgen, die dieser Regel nicht entsprechen, werden beim Rendern als abgelehnter Platzhalter gemeldet.

Ein vorangestellter Rückstrich unterdrückt die Ersetzung. Aus `\{{thema}}` wird im Ergebnis `{{thema}}`, der Rückstrich selbst entfällt.

### 5.3 Keyword

Ein wiederverwendbarer Textbaustein mit fester Position: vorangestellt oder nachgestellt. Die Reihenfolge mehrerer Keywords wird über einen Sortierwert bestimmt.

### 5.4 Workspace

Ein Workspace regelt Zugehörigkeit und Zugriff. Jeder Benutzer verfügt über einen persönlichen Workspace. Für die Zusammenarbeit werden gemeinsame Workspaces angelegt. Die Rollen sind `viewer`, `editor`, `admin` und `owner`. Zusätzlich besteht die Berechtigung zur Instanzverwaltung.

Die Sichtbarkeit eines Prompts wird davon unabhängig festgelegt:

| Sichtbarkeit | Zugriff |
|---|---|
| `private` | nur der Eigentümer |
| `workspace` | alle Mitglieder des Workspace |
| `instance` | alle angemeldeten Benutzer |

Eine Ordnerstruktur besteht nicht. Die Zuordnung erfolgt über den Workspace, das Wiederfinden über Schlagworte und Volltextsuche.

### 5.5 Wiederherstellung von Inhalten

| Fall | Vorgehen |
|---|---|
| Prompt versehentlich überschrieben | Funktion „Letzte Änderung rückgängig“ |
| Prompt gelöscht | Papierkorb, Aufbewahrung 30 Tage |
| Älterer Stand erforderlich | Nur über wiederholtes „Letzte Änderung rückgängig“ oder über eine Sicherung |

> **Hinweis:** Eine Liste aller Revisionen mit freier Auswahl eines Standes besteht in dieser Fassung nicht. Jeder Aufruf von „Letzte Änderung rückgängig“ nimmt den jüngsten gespeicherten Stand und verbraucht ihn dabei. Die Zahl der aufbewahrten Stände richtet sich nach `retention.revisions_per_prompt` und `retention.revisions_min_days`.

---

## 6. Datensicherung und Wiederherstellung

```bash
scripts/backup.sh                  # erzeugt eine Sicherung unter data/backups/
scripts/restore.sh                 # listet die vorhandenen Sicherungen
scripts/restore.sh <datei>         # spielt eine Sicherung zurück, mit Rückfrage
scripts/restore.sh <datei> --yes   # ohne Rückfrage, für automatisierte Abläufe
```

> **Achtung:** Vor dem Zurückspielen ist die Anwendung zu beenden. `restore` prüft den konfigurierten Port und bricht ab, solange die Instanz antwortet.

Ein Dateiname ohne Pfadangabe wird gegen `data/backups/` aufgelöst. Eine Sicherung von einem anderen Ort verlangt einen absoluten Pfad. Der Aufruf ohne Argument listet die jüngsten Sicherungen und ist der einfachste Weg, den Dateinamen zu erfahren.

> **Achtung:** Die Datenbankdatei darf nicht von Hand kopiert werden. Im WAL-Modus liegt ein Teil der Daten in Nebendateien. Eine manuelle Kopie ist unbrauchbar oder unvollständig, ohne dass eine Integritätsprüfung dies anzeigt. Das Sicherungsskript erzeugt eine konsistente Datei im laufenden Betrieb.

In die Sicherung gehören:

| Verzeichnis oder Datei | Begründung |
|---|---|
| `data/backups/*.db` | die Sicherungen selbst |
| `config/config.yml` | die Betriebswerte der Installation. Ohne sie startet eine wiederhergestellte Instanz mit den Standardwerten |
| `data/logs/` | nur bei Aufbewahrungspflicht für Protokolle |

`restore` liest die angegebene Sicherung vollständig, bevor Daten überschrieben werden. Eine unbrauchbare Datei führt daher nicht zu Datenverlust. Zusätzlich legt das Skript vor dem Ersetzen eine Sicherheitskopie des bisherigen Bestandes an und nennt deren Pfad am Ende.

Nach einer Wiederherstellung sind alle Benutzer abgemeldet. Sitzungen werden in der Datenbank geführt und auf den Stand der Sicherung zurückgesetzt.

---

## 7. Aktualisierung

1. Sicherung erzeugen: `scripts/backup.sh`
2. Dienst beenden
3. Die Verzeichnisse `app/`, `scripts/` und `doc/` sowie `README.md` und `LICENSE` durch die neue Fassung ersetzen
4. Schema aktualisieren: `scripts/migrate.sh`
5. Dienst starten
6. Zustandsendpunkt `/health` abfragen

Die Verzeichnisse `config/` und `data/` bleiben dabei unverändert.

`migrate` erzeugt vor jedem Schemaschritt selbsttätig eine Sicherung. Der Aufruf `scripts/migrate.sh --status` gibt die ausstehenden Schritte aus, ohne Änderungen vorzunehmen.

Stimmen Schemastand und Anwendungsfassung nicht überein, startet die Anwendung nicht und benennt den erforderlichen Schritt.

---

## 8. Betrieb hinter einem Reverse Proxy

Im Auslieferungszustand nimmt die Anwendung Verbindungen ausschließlich über `127.0.0.1` entgegen. Für den Zugriff aus dem Netz bestehen zwei Möglichkeiten:

1. Einen Reverse Proxy vorschalten, der die TLS-Verbindung terminiert, und `server.host` unverändert lassen. Dies ist die empfohlene Betriebsform.
2. `server.host` auf `0.0.0.0` setzen. Die Anwendung ist dann unverschlüsselt im Netz erreichbar.

Beispielkonfigurationen für nginx und Apache liegen unter `doc/examples/`.

In `config/config.yml` sind dafür zwei bereits vorhandene Werte zu **ändern**:

```yaml
server:
  host: "127.0.0.1"            # unverändert lassen
  port: 9292                   # unverändert lassen
  base_url: "https://…"        # die Adresse, unter der der Proxy erreichbar ist
  trusted_proxies: ["127.0.0.1"]   # bisher []

security:
  force_https: true            # bisher false
```

> **Achtung:** Die Blöcke `server` und `security` bestehen in der Datei bereits. Werden sie ein zweites Mal angefügt, verwirft YAML den ersten Block ohne Meldung. `host`, `port` und `base_url` fehlen dann, werden aus der Vorlage ergänzt, und die Instanz läuft nach dem Neustart auf einem anderen Port.

Über HTTPS trägt das Sitzungs-Cookie das Merkmal `Secure` bereits aufgrund des Protokolls. `force_https` bewirkt die Umleitung von HTTP auf HTTPS und setzt `Secure` auch dann, wenn die Anwendung selbst über HTTP angesprochen wird. Bei Aufrufen über `localhost`, `127.0.0.1` und `::1` findet weder eine Umleitung statt noch wird `Secure` gesetzt. Ein Versuch auf der Maschine selbst zeigt die Einstellung daher nicht.

> **Achtung:** Ohne Eintrag in `trusted_proxies` wird die Kopfzeile `X-Forwarded-For` nicht ausgewertet. Alle Anfragen erscheinen dann mit der Adresse des Proxys, und die Begrenzung der Anmeldeversuche je Adresse wirkt für alle Benutzer gemeinsam. Ein Eintrag, der nicht der eigenen Infrastruktur entspricht, erlaubt es beliebigen Aufrufern, eine falsche Adresse anzugeben.

---

## 9. Störungsbehebung

| Beobachtung | Ursache | Vorgehen |
|---|---|---|
| Start bricht ab und nennt einen Schlüssel | ungültiger Wert oder Schreibfehler in `config.yml` | Meldung nennt Schlüssel und erwarteten Wertebereich |
| Start bricht mit `EADDRINUSE` ab | Port belegt | anderen Port konfigurieren oder belegenden Prozess beenden |
| Start bricht mit Schemameldung ab | Schemastand und Anwendungsfassung stimmen nicht überein | `scripts/migrate.sh` |
| Instanz von anderen Rechnern nicht erreichbar | Bindung an `127.0.0.1` | siehe [Kapitel 8](#8-betrieb-hinter-einem-reverse-proxy) |
| Nach Wiederherstellung sind alle abgemeldet | Sitzungen werden in der Datenbank geführt | erneute Anmeldung |
| Keine Anmeldung mehr möglich | Verwaltungskonto gesperrt oder Passwort unbekannt | siehe Abschnitt 9.1 |

### 9.1 Notfallzugang

Ein Zurücksetzen des Passworts per E-Mail besteht nicht. Für den Fall, dass keine Anmeldung mehr möglich ist, steht folgender Weg zur Verfügung:

```bash
scripts/reset_admin_password.sh                       # einziges Verwaltungskonto
scripts/reset_admin_password.sh anna@example.test     # bestimmtes Konto
scripts/reset_admin_password.sh --generate            # Passwort wird erzeugt
```

Ohne Angabe einer Adresse arbeitet das Skript nur, wenn genau ein Konto mit Instanzverwaltungsrechten besteht. Bestehen mehrere, werden die Adressen ausgegeben und keine Änderung vorgenommen.

Bei jeder Ausführung werden alle Sitzungen des betroffenen Kontos beendet, der Vorgang wird im Prüfprotokoll vermerkt, und das Konto muss bei der nächsten Anmeldung ein eigenes Passwort vergeben.

Der Weg setzt Zugriff auf den Rechner und auf das Installationsverzeichnis voraus, nicht lediglich auf das Netz.

### 9.2 Fehlermeldungen und Protokoll

Die Oberfläche zeigt bei serverseitigen Fehlern eine allgemeine Meldung mit einer Kennung an. Pfade, Abfragen und Stapelspuren erscheinen ausschließlich im Protokoll unter `data/logs/`. Über die Kennung lässt sich der zugehörige Protokolleintrag auffinden.

---

## 10. Skriptübersicht

Alle Skripte liegen unter `scripts/` und stehen je einmal als `.sh` und als `.bat` zur Verfügung. Die Startdateien enthalten keine eigene Logik. Der Rückgabewert `0` bedeutet erfolgreiche Ausführung.

Die Beispiele in dieser Anleitung zeigen die Linux-Form. Unter Windows gilt jeweils die gleichnamige Datei mit der Endung `.bat`, also `scripts\backup.bat` statt `scripts/backup.sh`.

> **Achtung:** Die Schreibweise der Werte ist nicht einheitlich. `install` und `measure` erwarten sie mit Gleichheitszeichen, `seed_demo` mit Leerzeichen. Mit Ausnahme von `measure` werden unbekannte Schalter ohne Meldung übergangen. Bleibt eine Angabe wirkungslos, ist zuerst die Schreibweise zu prüfen.

Bei `reset_admin_password` ist die Adresse kein Schalter, sondern ein freies Argument. Sie wird am enthaltenen `@` erkannt.

| Skript | Wesentliche Schalter | Zweck |
|---|---|---|
| `check_environment` | `--operation-only`, `--all`, `--skip-gems` | Voraussetzungen prüfen |
| `install` | `--port=`, `--mode=`, `--admin-name=`, `--admin-email=`, `--admin-password=` | Erstinstallation |
| `start_portable` | `--no-backup` | Start im Vordergrund |
| `service_install` | `--system` | Dienst einrichten |
| `service_uninstall` | `--system` | Dienst entfernen |
| `migrate` | `--status` | Datenbankschema aktualisieren |
| `backup` | `--no-rotate` | Sicherung erzeugen |
| `restore` | `<datei>`, `--yes` | Sicherung zurückspielen |
| `reset_admin_password` | `[adresse]`, `--generate` | Notfallzugang |
| `seed_demo` | `--remove`, `--yes`, `--email <adresse>` | Beispielinhalte anlegen oder entfernen |
| `package` | `[zielverzeichnis]`, `--zip` | Installation als Archiv ausgeben |
| `export_all` | `[datei]` | Instanz als Umzugsdatei ausgeben |
| `import_all` | `<datei>` | Umzugsdatei in eine leere Instanz einspielen |
| `measure` | `--prompts=`, `--runs=`, `--serve` | Leistungswerte auf der Zielmaschine ermitteln |

Die vollständige Referenz enthält das `operations.de.md`.

Nicht ausgeliefert werden `build`, `start_development` und `run_tests`. Diese Skripte gehören zur Entwicklungsumgebung.

### 10.1 Umzug auf eine andere Instanz

| Verfahren | Einsatz |
|---|---|
| `backup` und `restore` | vollständige Übernahme des Bestands einschließlich Konten und Prüfprotokoll |
| `export_all` und `import_all` | Übernahme der Inhalte in eine neu aufgesetzte Instanz |

Die Umzugsdatei enthält keine Passwörter. Jedes Konto erhält beim Einspielen ein Einmalpasswort, das einmalig ausgegeben wird. `import_all` arbeitet ausschließlich auf einer Instanz ohne bestehende Konten.

---

## 11. Sicherheitsmerkmale

| Bereich | Umsetzung |
|---|---|
| Passwörter | Argon2id. Klartext wird weder gespeichert noch protokolliert noch in Antworten übertragen |
| Sitzungen | Zufallstoken, in der Datenbank nur als Hashwert. Cookie-Merkmale `HttpOnly` und `SameSite=Strict`, hinter HTTPS zusätzlich `Secure` |
| Schreibende Zugriffe | Prüfung eines CSRF-Tokens. Andernfalls Statuscode 403 |
| Anmeldeversuche | höchstens 5 je Konto und 20 je Adresse innerhalb von 15 Minuten |
| Import und Export | höchstens 5 Vorgänge je Minute und Benutzer |
| Prüfprotokoll | erfasst sicherheitsrelevante Vorgänge und ist über die Oberfläche nicht änderbar |
| Fehlermeldungen | enthalten keine Pfade, Abfragen oder Stapelspuren |

Die Anwendung leitet keine Daten an Dritte weiter und benötigt zur Laufzeit keine externen Dienste. Die Instanzverwaltung umfasst Konten und Workspaces, jedoch keinen Lesezugriff auf fremde Prompt-Inhalte. Ein Zugriff ist nur über eine Mitgliedschaft möglich, die im Prüfprotokoll vermerkt wird.

---

## 12. Mengenbegrenzungen

| Feld oder Menge | Grenze |
|---|---|
| Titel | 200 Zeichen |
| Beschreibung | 1.000 Zeichen |
| Prompt-Text | 100.000 Zeichen |
| Variablen je Prompt | 50 |
| Auswahloptionen je Variable | 100 |
| Schlagworte je Prompt | 20 |
| Keywords je Workspace | 200 |
| Gleichzeitig aktive Keywords | 20 |
| Modellhinweis | 200 Zeichen |
| Standardwert je Variable | 2.000 Zeichen |
| Name eines Schlagworts oder Keywords | 40 Zeichen |
| Text eines Keywords | 5.000 Zeichen |
| Name eines Workspace | 100 Zeichen |
| Importdatei | 10 MB |
| Gerenderter Prompt | 200.000 Zeichen |
| Schreibende Aufrufe | 120 je Minute und Sitzung |

Die Grenzen werden serverseitig geprüft. Bei Überschreitung wird der Vorgang abgelehnt und die Grenze in der Meldung genannt.
