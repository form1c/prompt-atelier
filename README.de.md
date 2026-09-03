[English](README.md) · **Deutsch**

# Prompt Atelier

Selbst betriebene Webanwendung zur Verwaltung und Wiederverwendung von AI-Prompts.

Prompts entstehen verstreut in Notizen, Chatverläufen und Textdateien. Prompt Atelier sammelt sie an einer Stelle, macht die veränderlichen Textteile zu Variablen und stellt den fertigen Text zum Kopieren bereit.

```
Prompt suchen  →  Felder ausfüllen  →  Vorschau prüfen  →  kopieren
```

---

## Funktionsumfang

| Bereich | Beschreibung |
|---|---|
| Bibliothek | Volltextsuche über Titel, Beschreibung, Text und Schlagworte. Umlaute und Schreibvarianten werden aufgelöst: `Größe` wird auch bei Eingabe von `groesse` oder `grosse` gefunden |
| Variablen | Platzhalter in doppelten geschweiften Klammern werden zu Formularfeldern mit Standardwert, Pflichtangabe und Auswahlliste. Unicode-Buchstaben sind zulässig |
| Live-Vorschau | Der fertige Text wird während der Eingabe aufgebaut. Browser und Server erzeugen dasselbe Ergebnis |
| Keywords | Wiederverwendbare Textbausteine, die einem Prompt vorangestellt oder nachgestellt werden |
| Workspaces | Persönliche, gemeinsame und instanzweite Bereiche mit den Rollen `viewer`, `editor`, `admin` und `owner` |
| Änderungsverlauf | Papierkorb mit 30 Tagen Aufbewahrung, Rücknahme der letzten Änderung, Revisionen je Prompt |
| Import und Export | JSON und Markdown, verlustfrei in beide Richtungen |
| Oberflächensprachen | Deutsch, Englisch, Französisch, Italienisch, Spanisch |

Die Anwendung erfordert eine Anmeldung, versendet keine E-Mails und ruft zur Laufzeit keine externen Dienste auf.

---

## Bildschirmfotos

| | |
|---|---|
| ![Login](img/PromptAtelier-Login.jpg)| ![Library](img/PromptAtelier-Library.jpg) |
| ![Create new Prompt](img/PromptAtelier-NewPrompt.jpg) |  ![Edit the execution prompt](img/PromptAtelier-ExecPrompt.jpg) |
| ![Keywords](img/PromptAtelier-Keywords.jpg) | ![Administration](img/PromptAtelier-Admin.jpg) |

---

## Systemanforderungen

| Umgebung | Anforderung |
|---|---|
| Linux | Ruby 3.3 oder neuer, mit Entwicklungsdateien und Übersetzer |
| Windows | Ruby 3.3 oder neuer, installiert als RubyInstaller mit DevKit |
| Beide | Bundler, 500 MB Plattenplatz, 1 GB Arbeitsspeicher, ein freier TCP-Port |

Node.js wird für den Betrieb nicht benötigt. Die Oberfläche ist in der Auslieferung fertig gebaut enthalten.

Debian 12 liefert Ruby 3.1 und erfüllt die Anforderung nicht. Debian 13 liefert Ruby 3.3, `ruby-full` bringt dort aber kein Bundler mit. Unter Debian und Ubuntu:

```bash
sudo apt install -y ruby-full ruby-dev build-essential curl
sudo gem install bundler -v 4.0.11
```

Die Anwendung ist für Instanzen mit bis zu 50 Benutzern und 20.000 Prompts ausgelegt.

---

## Installation

Das Archiv von der [Releases-Seite](../../releases) herunterladen. Angeboten wird ein plattformunabhängiges Archiv, das auf jedem unterstützten System läuft.

```bash
tar -xzf promptatelier-1.0.1-universal.tar.gz
cd promptatelier-1.0.1-universal
scripts/install.sh
```

Unter Windows das ZIP-Archiv entpacken und `scripts\install.bat` ausführen.

Das Installationsskript prüft die Voraussetzungen, legt Konfiguration, Datenbank und das erste Benutzerkonto an, richtet die gewählte Betriebsart ein und startet die Instanz abschließend zur Kontrolle. Danach wird die Adresse ausgegeben. Bei unveränderten Standardwerten lautet sie <http://127.0.0.1:9292>.

### Starten

```bash
scripts/start_portable.sh      # im Vordergrund, Strg+C beendet die Anwendung
scripts/service_install.sh     # als Systemdienst mit automatischem Start
```

### Erste Schritte

1. Die Adresse im Browser öffnen und mit dem bei der Installation angelegten Konto anmelden.
2. Optional Beispielinhalte laden: `scripts/seed_demo.sh`. Der Aufruf mit `--remove` entfernt sie wieder.
3. Einen Prompt öffnen, die Felder ausfüllen und den Text kopieren.

### Datensicherung

```bash
scripts/backup.sh              # erzeugt eine Sicherung im laufenden Betrieb
scripts/restore.sh <datei>     # spielt eine Sicherung zurück
```

> **Achtung:** Die Datenbankdatei darf nicht von Hand kopiert werden. Im WAL-Modus liegt ein Teil der Daten in Nebendateien. Eine manuelle Kopie ist unvollständig, ohne dass eine Integritätsprüfung dies anzeigt.

---

## Dokumentation

| Dokument | Inhalt |
|---|---|
| [Anleitung](doc/installation.de.md) | Vollständige Installations- und Betriebsanleitung für beide Betriebssysteme und alle Betriebsarten |
| [Betriebshandbuch](doc/operations.de.md) | Nachschlagewerk für den laufenden Betrieb einschließlich der Referenz aller Skripte |
| [Entwicklerhandbuch](doc/development.de.md) | Aufbau des Quelltextes, Entwicklungsumgebung, Entwurfsentscheidungen |

Die englischen Fassungen liegen jeweils daneben. Weitere Projektdateien sind [CHANGELOG.md](CHANGELOG.md), [CONTRIBUTING.md](CONTRIBUTING.md) und [SECURITY.md](SECURITY.md), sämtlich auf Englisch.

---

## Technischer Aufbau

Ruby 3.3 mit Sinatra 4 als JSON-Schnittstelle, Vue 3 als Single-Page-Anwendung, SQLite mit FTS5-Volltextsuche und Puma als Anwendungsserver. Ein Prozess, eine Datenbankdatei, keine externen Laufzeitabhängigkeiten.

Die Anwendung ist nicht als Chat-Client, Modell-Playground oder Wiki konzipiert. Das direkte Senden von Prompts an ein Sprachmodell ist für eine spätere Fassung vorgesehen.

---

## Lizenz

[MIT](LICENSE.md), Copyright (c) 2026 formic.

Die mitgelieferten Bibliotheken stehen unter MIT, ISC, Apache-2.0 oder BlueOak. Das plattformgebundene Archiv enthält die Ruby-Bibliotheken einschließlich ihrer Lizenztexte.
