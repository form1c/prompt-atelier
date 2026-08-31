[English](development.md) · **Deutsch**

# Prompt Atelier: Entwicklerhandbuch

| | |
|---|---|
| **Fassung** | 2.1 |
| **Stand** | 2026-08-30 |
| **Zielgruppe** | Entwicklung am Quelltext |
| **Nicht enthalten** | Installation und Betrieb einer Auslieferung. Siehe `installation.de.md` und `operations.de.md` |

Dieses Handbuch beschreibt den Aufbau des Quelltextes und die Entwurfsentscheidungen dahinter. Wo eine Entscheidung willkürlich wirkt, steht die Begründung daneben.

---

## Inhalt

1. [Überblick](#1-überblick)
2. [Entwicklungsumgebung einrichten](#2-entwicklungsumgebung-einrichten)
3. [Verzeichnisaufbau](#3-verzeichnisaufbau)
4. [Tests](#4-tests)
5. [Architektur](#5-architektur)
6. [Datenbank und Migrationen](#6-datenbank-und-migrationen)
7. [Rendering-Pipeline](#7-rendering-pipeline)
8. [Suche und Normalisierung](#8-suche-und-normalisierung)
9. [Anmeldung und Schutzschichten](#9-anmeldung-und-schutzschichten)
10. [Konfiguration](#10-konfiguration)
11. [Übersetzungen](#11-übersetzungen)
12. [Oberfläche](#12-oberfläche)
13. [Bauen und Ausliefern](#13-bauen-und-ausliefern)
14. [Bewusste Entwurfsentscheidungen](#14-bewusste-entwurfsentscheidungen)

---

## 1. Überblick

| Schicht | Technik |
|---|---|
| Anwendungsserver | Puma 8 |
| Schnittstelle | Sinatra 4 als reine JSON-API unter `/api/v1` |
| Datenhaltung | SQLite über Sequel, Volltextsuche über FTS5 |
| Oberfläche | Vue 3 als Single-Page-Anwendung, gebaut mit Vite 7 |
| Passwörter | Argon2id |

Die Anwendung läuft als einzelner Prozess gegen eine einzelne Datenbankdatei. Es bestehen keine Laufzeitabhängigkeiten zu externen Diensten.

Zwei Festlegungen prägen den gesamten Entwurf:

**Ein Objekt statt zweier.** Es gibt keine getrennte Objektart für Vorlagen. Enthält der Text eines Prompts Platzhalter, wirkt er als Vorlage. Damit entfällt die doppelte Verwaltung von Fassung, Status und Modellbezug.

**Mandantenfähig gebaut.** Jede inhaltstragende Tabelle führt `workspace_id`, und jede Abfrage filtert serverseitig darüber. Der nachträgliche Einbau wäre erheblich aufwendiger als der sofortige.

---

## 2. Entwicklungsumgebung einrichten

### 2.1 Voraussetzungen

| Bestandteil | Fassung |
|---|---|
| Ruby | 3.3 oder neuer |
| Node.js | 20.19 oder neuer, alternativ 22.12 oder neuer |
| Bundler | aktuelle Fassung |

Vite 7 weist die Node-Reihen 20.0 bis 20.18, 21.x und 22.0 bis 22.11 ab.

### 2.2 Einrichtung

```bash
cd project

# 1. Ruby-Abhängigkeiten
BUNDLE_GEMFILE=backend/Gemfile bundle lock
cd backend && bundle config set --local deployment true && cd ..
BUNDLE_GEMFILE=backend/Gemfile bundle install

# 2. Node-Abhängigkeiten
npm ci                      # beim ersten Mal: npm install

# 3. Konfiguration
cp config/config.example.yml config/config.yml
chmod 600 config/config.yml

# 4. Datenbank und Start
scripts/migrate.sh
scripts/start_development.sh
```

**Die Reihenfolge in Schritt 1 ist bindend.** `bundle config set --local deployment true` verlangt eine vorhandene `Gemfile.lock` und bricht andernfalls mit der Meldung `The deployment setting requires a lockfile` ab. In einer Auslieferung liegt die Sperrdatei bei, in einem frischen Arbeitsverzeichnis entsteht sie erst durch `bundle lock`.

**`BUNDLE_GEMFILE` ist erforderlich.** `Gemfile` und `Gemfile.lock` liegen in `backend/`, weil sie beim Update mit ersetzt werden. Ohne die Angabe findet Bundler sie nicht.

**`npm ci` läuft in `project/`, nicht in `frontend/`.** Von `project/tests/frontend/` aus wäre ein `frontend/node_modules` nicht auflösbar, und jeder Vitest-Lauf würde beim Auflösen der Importe abbrechen.

### 2.3 Adressen in der Entwicklung

| Dienst | Adresse |
|---|---|
| Vite-Entwicklungsserver | <http://127.0.0.1:5173> |
| Backend | <http://127.0.0.1:9292> |

Der Browser ist auf den Vite-Server zu richten. In der Entwicklung ist `backend/public/` leer, weil die Oberfläche nicht gebaut vorliegt. Vite leitet `/api`, `/health` und `/version` an das Backend weiter.

---

## 3. Verzeichnisaufbau

```
project/
├── backend/          Anwendung
│   ├── app.rb        Routen, Schutzschichten, Antwortformat
│   ├── config.ru     Rack-Einstiegspunkt
│   ├── version.rb    Fassungsnummer, einzige Quelle
│   ├── services/     Fachlogik, 27 Module
│   ├── migrations/   Schemaschritte, Dateiname gleich Schemastand
│   ├── locales/      Konsolentexte, ausschließlich en.json
│   └── public/       gebaute Oberfläche, entsteht durch build
├── frontend/src/     Vue-Oberfläche
│   ├── api/          Aufrufe, Fehlergestalt, Sitzungsablauf
│   ├── state/        Anwendungszustand
│   ├── views/        Bildschirme
│   ├── components/   wiederverwendbare Bestandteile
│   ├── locales/      fünf Sprachdateien
│   └── util/         Rendering, Normalisierung, Hilfsfunktionen
├── doc/              Handbücher auf Englisch und Deutsch
├── img/              Bildschirmfotos für die README
├── scripts/          17 Startdateipaare, Logik in scripts/lib/
├── tests/            Minitest, Vitest, Playwright, Vektoren, Fixtures
├── examples/         Beispielpaket für den Leerzustand
├── config/           config.example.yml als Quelle aller Standardwerte
├── README.md         Einstieg, zusätzlich als README.de.md
└── LICENSE.md        MIT-Lizenz
```

`project/` entspricht dem Installationsverzeichnis einer Auslieferung. `project/backend/` entspricht dort `app/`.

---

## 4. Tests

```bash
scripts/run_tests.sh                  # Backend und Frontend
scripts/run_tests.sh --e2e            # zusätzlich die Browsertests
scripts/run_tests.sh --only=backend   # einzelne Suite
```

| Ebene | Werkzeug | Gegenstand |
|---|---|---|
| Backend | Minitest | Fachlogik, Schnittstelle, Skripte |
| Frontend | Vitest | Komponenten und Zustand |
| Browser | Playwright | durchgehende Abläufe in Chromium, Firefox, WebKit und bei 360 px Breite |

Testläufe legen ihre Ergebnisse unter `test-results/` ab. Das Verzeichnis liegt außerhalb von `project/`, damit ein Testlauf die Entwicklungsdatenbank nicht berühren kann.

### 4.1 Grundsätze

**Eine neue Testmenge, die beim ersten Lauf vollständig grün ist, wird durch Mutation geprüft.** Dazu wird die geprüfte Stelle im Quelltext gezielt beschädigt und festgestellt, ob ein Fall fehlschlägt. Bleibt alles grün, prüft der Test nicht das, was er zu prüfen vorgibt.

**Geprüft wird die Wirkung, nicht die Einstellung.** Ein Test, der einen konfigurierten Wert vergleicht, sagt nichts darüber aus, ob dieser Wert etwas bewirkt.

**Jeder Testfall stellt selbst her, was er braucht.** Die Browsertests teilen sich eine Instanz. Ein Fall, der auf einen von einem anderen Fall angelegten Zustand baut, ist einzeln ausgeführt nicht lauffähig.

**Ein Ersatzserver ist selbst Prüfgegenstand.** Antwortet er anders als der echte Server, prüft der Test eine Erfindung.

### 4.2 Prüfungen gegen Projektdokumente

Drei Prüfungen vergleichen den Quelltext mit internen Projektdokumenten, statt die Anwendung zu prüfen. Diese Dokumente sind nicht Teil dieses Repositorys.

| Prüfung | Zweck |
|---|---|
| `acceptance_protocol_test` | Zu jedem Abnahmekriterium ist ein Ergebnis festgehalten |
| `test_case_register_test` | Jede im Quelltext verwendete Testfallnummer ist eine definierte |
| `plan_packages_test` | Jedes Arbeitspaket steht in der Projektübersicht |

**In einem Klon überspringen diese neun Fälle**, mit Angabe des Grundes in der Ausgabe. Sie benötigen Dateien, die nicht veröffentlicht werden. Ein übersprungener Lauf ist erwartet und kein Fehlschlag.

### 4.3 Sprachprüfungen

| Prüfung | Gegenstand |
|---|---|
| `one_language_test` | keine deutschen Fachwerte im Quelltext |
| `console_language_test` | keine deutschen Zeichenketten in der Konsolenausgabe |

Beide sind getrennt, weil sie verschiedene Wortmengen suchen. Die Wortliste der zweiten Prüfung beweist kein Englisch. Sie erkennt die Wörter, die sie führt, und benennt diese Grenze in der Datei.

---

## 5. Architektur

### 5.1 Schnittstelle

`backend/app.rb` enthält die Routen und die Schutzschichten. Die Fachlogik liegt vollständig in `backend/services/`. Eine Route nimmt entgegen, prüft Berechtigungen über `Access` und ruft ein Dienstmodul auf.

Der `before`-Block verarbeitet jede Anfrage in fester Reihenfolge:

1. Anforderungskennung vergeben, damit ein späterer Fehler einem Aufruf zuzuordnen ist
2. HTTPS erzwingen, sofern konfiguriert
3. Sicherheitskopfzeilen setzen
4. Sitzung auflösen
5. Sprache bestimmen (11.7)
6. Sitzungs-Cookies erneuern
7. CSRF prüfen bei schreibenden Aufrufen
8. Mengengrenzen prüfen
9. Aufräumlauf anstoßen, sofern für diesen Kalendertag noch keiner lief

Der letzte Schritt ist der einzige, der nicht zur Anfrage gehört. `sweep_if_due` markiert den Tag vor der Arbeit als erledigt, sodass gleichzeitige Anfragen den Lauf nicht mehrfach auslösen. Eine Instanz ohne Zugriffe räumt nicht auf.

Die Sprache wird vor allen ablehnenden Prüfungen bestimmt, damit auch eine Ablehnung in der richtigen Sprache erfolgt.

### 5.2 Berechtigungen

`services/access.rb` ist die einzige Stelle, an der über Zugriff entschieden wird. Sie liefert für eine Kombination aus Aktion, Rolle, Eigentum und Sichtbarkeit ein Urteil.

Die Sichtbarkeitsbedingung besteht als SQL-Fragment mit Werteliste, nicht nur als Prüfung auf einem geladenen Datensatz. Nur so lässt sie sich in die Suchabfrage einsetzen. Ein nachgelagertes Aussieben würde Blätterung und Rangfolge über Zeilen berechnen, die der Aufrufer nicht sehen darf.

### 5.3 Antwortformat

Antworten sind JSON. Fehler tragen einen maschinenlesbaren Code, nicht nur einen Satz. Die Oberfläche verzweigt auf den Code und bildet den Text selbst, damit derselbe Fehler in jeder Sprache erscheint.

Zeitangaben folgen ISO 8601 mit Zeitzone. Rubys Standardausgabe eines `Time` entspricht dem nicht und wird umgeformt.

---

## 6. Datenbank und Migrationen

### 6.1 Aufbau

Migrationen sind Ruby-Dateien unter `backend/migrations/`. Der Dateiname enthält die Fassungsnummer. Sie werden mit `load` eingelesen und hinterlassen keinen prozessweiten Zustand.

Ruby statt SQL, weil die Trigger den Normalisierungsausdruck benötigen, der aus `services/normalization.rb` erzeugt wird.

Datenbankeinstellungen hängen an `after_connect` von Sequel, nicht an einem einmaligen Aufruf. Andernfalls hätten später geöffnete Verbindungen keine Fremdschlüsselprüfung.

### 6.2 Wartezeit bei Schreibkonflikten

`PRAGMA busy_timeout` hält den gesamten Prozess an, weil SQLite in C wartet, ohne die globale Sperre von Ruby freizugeben. Verwendet wird stattdessen `busy_handler_timeout` des sqlite3-Gems.

Die Reihenfolge ist bindend: Das Setzen eines Handlers löscht `busy_timeout`, und ein späteres `PRAGMA busy_timeout` setzt den blockierenden Handler wieder ein.

### 6.3 Volltextindex

Die Suche verwendet FTS5 mit externer Inhaltstabelle. Spiegelspalten tragen die normalisierten Werte und werden über Trigger gepflegt.

Ein Wiederaufbau über das FTS5-Kommando `rebuild` füllt den Index aus der Inhaltstabelle und zerstört dabei die Normalisierung. Der Wiederaufbau erfolgt deshalb über die Spiegelspalten.

Beim Löschen benötigt der Index die **alten** indizierten Werte. Andernfalls bleiben verwaiste Begriffe zurück, die `integrity-check` mit Argument meldet, ohne Argument jedoch nicht.

### 6.4 Migration 006

Die jüngste Migration führt `prompts.title_sort` ein und legt einen Index über `(workspace_id, title_sort)` an. Sie arbeitet in acht Schritten:

1. Volltextindex leeren
2. Spalte anlegen
3. sechs Trigger entfernen
4. Werte für alle Zeilen berechnen
5. Index anlegen
6. Trigger neu anlegen, jetzt einschließlich `title_sort`
7. Volltextindex füllen
8. Ergebnis prüfen

Der Index muss vor der Neuberechnung geleert werden, weil er die alten Werte der Spiegelspalten führt.

Ein Trigger kann keinen Ausdruck als Rumpf haben. Die sechs Trigger werden deshalb ersetzt und nicht geändert.

Anders als Migration 005 kommt 006 ohne abgeschaltete Fremdschlüsselprüfung aus. 005 baut Tabellen um, und ein `DROP TABLE` löst bei eingeschalteter Prüfung `ON DELETE CASCADE` aus.

Sortiert wird nach `title_sort`. `ORDER BY title` ergäbe eine Bytefolge, in der Großbuchstaben vor Kleinbuchstaben und alle akzentuierten Zeichen dahinter stehen.

---

## 7. Rendering-Pipeline

Die Pipeline ist in fünf Schritten festgelegt. Die Zählung stammt aus der Spezifikation und wird im Quelltext unverändert verwendet:

| Schritt | Vorgang |
|---|---|
| 1 | Ausgangstext des Prompts |
| 2 | Variablen ersetzen |
| 2b | Fluchtzeichen auflösen |
| 3 | Keywords anwenden, nach Position und Sortierwert |
| 4 | Leerraum normalisieren |

Schritt 2b ist bewusst ein eigener Schritt. In einem Durchgang mit Schritt 2 wäre die Reihenfolge beider Regeln von außen nicht beobachtbar, und die JavaScript-Fassung könnte sie anders wählen.

### 7.1 Zwei Fassungen, ein Prüfstand

Die Pipeline besteht in Ruby und in JavaScript und muss zeichengleich rechnen. Abgesichert wird das über 34 gemeinsame Vektoren in `tests/vectors/rendering.json`, die beide Seiten gegen dieselbe Datei prüfen.

Eine Abweichung zwischen beiden Fassungen gilt als sperrend. Kein weiteres Arbeitspaket wird begonnen, solange sie besteht.

### 7.2 Zeichenvorrat der Platzhalter

| Umgebung | Ausdruck |
|---|---|
| Ruby | `[[:alpha:]][[:alnum:]_]{0,39}` |
| JavaScript | `[\p{L}][\p{L}\p{N}_]{0,39}` mit `u`-Flag |

Zulässig sind Unicode-Buchstaben, damit Platzhalter wie `{{prénom}}` oder `{{año}}` erkannt werden. Zuvor blieben sie wörtlich stehen und wurden nicht einmal als unbekannte Variable gemeldet, weil sie nicht als Variable erkannt wurden.

**Das `u`-Flag ist in JavaScript zwingend.** Ohne das Flag bedeutet `\p{L}` vier wörtliche Zeichen, ohne Fehlermeldung.

Zeichenfolgen, die der Regel nicht entsprechen, werden über `rejected_keys` gemeldet. Die Erweiterung des Zeichenvorrats verschiebt die Grenze, sie hebt sie nicht auf.

Die Falltabelle liegt als `tests/fixtures/placeholder_cases.json` und wird von beiden Seiten gelesen.

---

## 8. Suche und Normalisierung

### 8.1 Normalisierung

`services/normalization.rb` erzeugt die Regel sowohl als Ruby-Funktion als auch als SQL-Ausdruck aus derselben Tabelle. Eine registrierte SQL-Funktion wäre nicht verwendbar, weil FTS5 und die sqlite3-Kommandozeile sie nicht kennen.

Umlaute und ihre Umschreibungen werden auf den Grundvokal abgebildet, damit `Größe`, `Groesse` und `Grosse` zusammenfallen.

`lower()` in SQLite arbeitet ausschließlich auf ASCII. Großbuchstaben mit Diakritika stehen deshalb ausdrücklich in der Ersetzungstabelle.

Eingaben werden mit `unicode_normalize(:nfc)` zusammengesetzt. Ohne diesen Schritt findet ein Suchbegriff mit zerlegten Zeichen nichts, auch keinen ebenso gespeicherten Prompt.

### 8.2 Suchbegriffe

Ein roh an FTS5 übergebener Suchbegriff kann die Abfrage zum Abbruch bringen. Die Aufbereitung normalisiert, zerlegt in alphanumerische Folgen, setzt jedes Wort als Präfixausdruck in Anführungszeichen und verbindet sie. Zeichen zwischen den Wörtern werden verworfen.

Bleibt kein Wort übrig, entfällt der Textfilter. Eine leere Ergebnismenge wäre falsch, weil ein Suchfeld mit ausschließlich Satzzeichen sonst die Bibliothek leeren würde.

Die Gewichtung erfolgt über `bm25` mit unterschiedlichen Faktoren für Titel, Beschreibung, Text und Schlagworte. `bm25` liefert negative Werte, kleinere Werte sind bessere Treffer.

Hervorgehoben wird auf dem Originaltext, nicht über die FTS5-Funktionen. Diese geben den normalisierten Text zurück, und eine Position im normalisierten Text lässt sich nicht eindeutig zurückrechnen.

---

## 9. Anmeldung und Schutzschichten

### 9.1 Passwörter

Argon2id über das argon2-Gem. `m_cost` ist der Zweierlogarithmus der Speichermenge in KiB, 64 MiB entsprechen also dem Wert 16.

Bei unbekannter Kennung wird ein vollständiger Durchlauf gegen einen festen Vergleichswert gerechnet. Dieser Wert ist eine Konstante. Würde er bei Bedarf erzeugt, wäre der erste Versuch messbar langsamer und die gleichlautende Fehlermeldung wertlos.

Die Sperrprüfung liegt **vor** der Passwortprüfung. Andernfalls kostete jeder Versuch eines gesperrten Aufrufers einen vollen Durchlauf, und die Begrenzung wirkte als Verstärker.

### 9.2 Sitzungen

Eine Sitzung wird über ein Zufallstoken geführt, von dem die Datenbank nur den SHA-256-Hashwert speichert. Ein Sitzungsgeheimnis in der Konfiguration besteht nicht.

Beide Cookies tragen ein Ablaufdatum in Höhe von `session.idle_timeout_days` und werden bei jedem angemeldeten Aufruf erneuert. Ohne Ablaufdatum verwirft der Browser sie beim Beenden, und die zugesagten 14 Tage wären nicht einzuhalten.

Das CSRF-Cookie läuft gleichzeitig ab. Überlebte es das Sitzungs-Cookie nicht, schlüge jeder schreibende Aufruf mit 403 fehl.

### 9.3 Mengenbegrenzungen

| Grenze | Wert | Bezugsgröße |
|---|---|---|
| schreibende Aufrufe | 120 je Minute | Sitzung |
| Import und Export | 5 je Minute | Benutzer |

Die zweite Grenze zählt je Benutzer, weil sie sonst mit jeder weiteren Anmeldung wüchse. Erfasst ist auch die Ausgabe der eigenen Kontodaten, obwohl sie ein `GET` ist.

Die Vorschau eines Imports ist ausgenommen. Sie schreibt nichts, und der vorgeschriebene Ablauf verlangt vor jedem Import eine Vorschau.

### 9.4 Absenderadresse

Ausgewertet wird die tatsächliche Adresse. `X-Forwarded-For` wird nur berücksichtigt, wenn der unmittelbare Absender in `server.trusted_proxies` steht, und dann von rechts gelesen.

Verwendet wird `REMOTE_ADDR`, nicht `request.ip`. Rack entscheidet selbst, welche Adressen es als Proxy ansieht, und diese Annahme ist nicht die Konfiguration des Betreibers.

---

## 10. Konfiguration

`services/configuration.rb` liest `config/config.yml` und legt `config/config.example.yml` als Standardwerte darunter. Die Vorlage ist damit nicht nur Dokumentation, sondern die einzige Quelle der Standardwerte.

Ein ungültiger Wert bricht den Start ab und nennt Schlüssel und erwarteten Bereich. Gesammelt werden alle Fehler, nicht nur der erste.

Unbekannte Schlüssel brechen den Start ebenfalls ab. Das ist strenger als nötig und in Kapitel 14 aufgeführt.

Die Prüfregeln liegen auf der Klasse und werden auch von den im Verwaltungsbereich einstellbaren Werten verwendet. Ein in ein Formular eingegebener Wert wird damit nach demselben Maßstab beurteilt wie ein in die Datei geschriebener.

`locale` wird auf die Form geprüft, nicht gegen die Dateien in `backend/locales/`. Die Sprachen der Oberfläche liegen im Bündel, wo der Server sie nicht zählen kann.

---

## 11. Übersetzungen

### 11.1 Aufteilung

| Ort | Inhalt |
|---|---|
| `frontend/src/locales/*.json` | Oberfläche, fünf Sprachen |
| `backend/locales/en.json` | Konsolenausgabe, ausschließlich Englisch |

Die Konsole spricht ausschließlich Englisch. Diese Zeilen liest, wer eine Instanz installiert und betreibt, auch auf fremden Rechnern. Sie werden in Suchmaschinen und Fehlerberichte eingefügt.

`en.json` der Oberfläche ist die Grundtabelle. Jede andere Sprache wird darüber gelegt, sodass ein fehlender Schlüssel von dort beantwortet wird.

### 11.2 Sprachwahl

| Aufruf | Prüft |
|---|---|
| `I18n.offered?(code)` | nur die Form, etwa `de` oder `pt-BR` |
| `I18n.available?(code)` | ob eine Datei der Konsole dafür besteht |

Die Trennung entstand aus einem Fehler. Eine gemeinsame Prüfung gegen die Serverdateien entschied auch über die Sprache der Oberfläche, deren Dateien im Bündel liegen. Ein französischer Browser erhielt Englisch, eine französische Profilwahl wurde verworfen, und `locale: fr` verhinderte den Start.

Der Server reicht den genauesten Sprachtag weiter. Aufgelöst wird er im Browser über `resolve()`, das die genaue Angabe, dann die Hauptsprache und zuletzt die Grundtabelle versucht.

Sprachnamen werden über `Intl.DisplayNames` ermittelt. Romanische Sprachen schreiben ihren eigenen Namen klein, weshalb der erste Buchstabe mit `toLocaleUpperCase(code)` umgesetzt wird.

---

## 12. Oberfläche

### 12.1 Aufbau

| Verzeichnis | Inhalt |
|---|---|
| `api/client.js` | Basispfad, CSRF-Kopf, Fehlergestalt, Behandlung abgelaufener Sitzungen |
| `state/` | Anwendungszustand über `reactive`, ohne Zustandsbibliothek |
| `router/` | Routen und Wächter |
| `views/` | Bildschirme |
| `components/` | Rahmen, Lade-, Leer- und Fehlerzustand, Einblendungen |

`/health` und `/version` liegen neben der Schnittstelle und werden ohne Präfix aufgerufen. Der Server führt sie ebenso, damit sich der Zustand einer Instanz abfragen lässt, ohne die Generation der Schnittstelle zu kennen.

Die beiden Endpunkte unterscheiden sich im Zugang. `/health` ist offen, weil eine Überwachung ihn ohne Konto erreichen muss. `/version` verlangt eine Anmeldung, weil die Fassungsnummer eines Dienstes keine öffentliche Angabe ist.

### 12.2 Abgelaufene Sitzung

Läuft eine Sitzung während einer Eingabe ab, öffnet sich eine Einblendung über dem Bildschirm. Die Eingaben bleiben erhalten, und der unterbrochene Aufruf wird nach der erneuten Anmeldung mit demselben Rumpf wiederholt.

Die Wiederholung schaltet die Wiederaufnahme für sich selbst ab. Andernfalls öffnete sich die Einblendung endlos.

### 12.3 Bildschirme werden fest eingebunden

Bildschirme werden nicht je Route nachgeladen. Das Bündel bleibt deutlich unter der zugesagten Grenze, und das Nachladen kostete je Bildschirm eine zusätzliche Rundreise.

---

## 13. Bauen und Ausliefern

```bash
scripts/build.sh                 # baut die Oberfläche und erzeugt die Archive
scripts/build.sh --skip-tests    # ohne vorherigen Testlauf
```

`build` führt den Testlauf aus und bricht bei Fehlschlägen ab. Der Teststand wird in die `VERSION`-Datei des Archivs geschrieben.

### 13.1 Zwei Archivgestalten

| Gestalt | Inhalt | Zweck |
|---|---|---|
| plattformgebunden | mit `vendor/bundle` | Installation ohne Internetzugang, gebunden an eine Plattform und eine Ruby-Reihe |
| universell | ohne Bibliotheken | jede Plattform, Bibliotheken werden bei der Installation bezogen |

Ohne die zweite Gestalt ließe sich von einem Linux-Rechner aus kein Paket für Windows bauen.

### 13.2 Reproduzierbarkeit

Die Archive werden selbst geschrieben und nicht an `tar` und `zip` übergeben. Reproduzierbarkeit ist eine Eigenschaft des Schreibers, und `zip` fehlt auf vielen Servern. `SOURCE_DATE_EPOCH` wird beachtet.

### 13.3 Was nicht ausgeliefert wird

| Bestandteil | Begründung |
|---|---|
| `node_modules/` | Ergebnis des Bauens |
| `frontend/`, `tests/`, `release/` | Quellen und Ergebnisse der Entwicklung |
| `config/config.yml` | beschreibt den bauenden Rechner, einschließlich der vertrauten Netze |
| Ruby selbst | wird über das Betriebssystem installiert |
| `build`, `run_tests`, `start_development` | benötigen Node oder das Testverzeichnis |

`run_tests` ist der wichtigste dieser Fälle. Ohne `tests/` fände es keine Testdatei, überspränge jede Suite und meldete abschließend, dass alle ausgeführten Tests bestanden haben.

### 13.4 Fassungsnummer

Die Fassungsnummer steht ausschließlich in `backend/version.rb`. Von dort gelangt sie in den Endpunkt `/version`, in die `VERSION`-Datei des Archivs und in den Archivnamen.

Sie gehört nicht in `config.yml`. Diese Datei wird beim Update bewusst nicht ersetzt, und eine Fassungsnummer darin bliebe nach dem ersten Update dauerhaft stehen.

---

## 14. Bewusste Entwurfsentscheidungen

Die folgenden Festlegungen können wie Versäumnisse wirken. Jede ist beabsichtigt, der Grund steht daneben.

| Festlegung | Grund |
|---|---|
| `project/` ist während der Entwicklung das Installationsverzeichnis, `config/` und `data/` liegen darin | Pfade lösen sich in der Entwicklung damit genauso auf wie in einer Auslieferung |
| Der npm-Arbeitsbereich hat seine `package.json` in `project/`, nicht in `frontend/` | Von `project/tests/frontend/` aus wäre ein `frontend/node_modules` nicht auflösbar, und jeder Vitest-Lauf bräche beim Auflösen der Importe ab |
| Unbekannte Schlüssel in `config.yml` brechen den Start ab | Andernfalls bleibt ein Schreibfehler ohne Wirkung und ohne Meldung |
| `test-results/` liegt außerhalb von `project/` | Ein Testlauf kann die Entwicklungsdatenbank damit nicht berühren |
| `puma.rb` leitet das Anwendungsverzeichnis aus dem eigenen Ort ab | Das Verzeichnis heißt in der Entwicklung `backend/` und in einer Auslieferung `app/` |
| `puma.rb` wendet die Standardwerte aus der Vorlage an | Sonst hätte ein in `config.yml` fehlender Wert keinen Rückfall |
| Der Vite-Server ist auf `127.0.0.1:5173` mit `strictPort` festgelegt | Ohne die Festlegung weicht Vite bei belegtem Port aus, und der Browser erreicht nichts mehr |
| `project/package.json` trägt `"type": "module"` | Die Playwright-Konfigurationsdateien sind ES-Module |
| `build` schreibt die Archive selbst statt `tar` und `zip` aufzurufen | Reproduzierbarkeit ist eine Eigenschaft des Schreibers, und `zip` fehlt auf vielen Servern |
| `build` erzeugt zwei Archivgestalten | Ohne die universelle Gestalt ließe sich von einem Linux-Rechner aus kein Paket für Windows bauen |
| `build`, `run_tests` und `start_development` werden nicht ausgeliefert | Sie brauchen Node oder das Testverzeichnis, und beides gehört nicht zur Auslieferung |
| Die Anwendung liefert die gebaute Oberfläche selbst aus | Ohne sie beantwortete ein Neuladen auf einer anwendungsseitigen Adresse mit der JSON-404 einer Schnittstelle |

Eine Festlegung dieser Art, die hier nicht aufgeführt ist, gilt als Fehler.
