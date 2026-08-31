**English** · [Deutsch](development.de.md)

# Prompt Atelier: Developer Manual

| | |
|---|---|
| **Version** | 2.1 |
| **Date** | 2026-08-30 |
| **Audience** | Development on the source |
| **Not covered** | Installing and running a release. See `installation.md` and `operations.md` |

This manual describes the layout of the source and the design decisions behind it. Where a decision looks arbitrary, the reason is given next to it.

---

## Contents

1. [Outline](#1-outline)
2. [Setting up the development environment](#2-setting-up-the-development-environment)
3. [Directory layout](#3-directory-layout)
4. [Tests](#4-tests)
5. [Architecture](#5-architecture)
6. [Database and migrations](#6-database-and-migrations)
7. [Rendering pipeline](#7-rendering-pipeline)
8. [Search and normalisation](#8-search-and-normalisation)
9. [Sign-in and protective layers](#9-sign-in-and-protective-layers)
10. [Configuration](#10-configuration)
11. [Translations](#11-translations)
12. [Interface](#12-interface)
13. [Building and releasing](#13-building-and-releasing)
14. [Deliberate design choices](#14-deliberate-design-choices)

---

## 1. Outline

| Layer | Technology |
|---|---|
| Application server | Puma 8 |
| Interface | Sinatra 4 as a pure JSON API under `/api/v1` |
| Storage | SQLite through Sequel, full-text search through FTS5 |
| User interface | Vue 3 as a single-page application, built with Vite 7 |
| Passwords | Argon2id |

The application runs as a single process against a single database file. There are no runtime dependencies on external services.

Two decisions shape the whole design:

**One object instead of two.** There is no separate object type for templates. If the body of a prompt contains placeholders, it acts as a template. This removes the duplicated handling of version, status and model reference.

**Built multi-tenant.** Every table carrying content has a `workspace_id`, and every query filters on it server-side. Retrofitting this would be considerably more expensive than doing it from the start.

---

## 2. Setting up the development environment

### 2.1 Requirements

| Component | Version |
|---|---|
| Ruby | 3.3 or newer |
| Node.js | 20.19 or newer, alternatively 22.12 or newer |
| Bundler | current version |

Vite 7 rejects the Node series 20.0 to 20.18, 21.x and 22.0 to 22.11.

### 2.2 Setup

```bash
cd project

# 1. Ruby dependencies
BUNDLE_GEMFILE=backend/Gemfile bundle lock
cd backend && bundle config set --local deployment true && cd ..
BUNDLE_GEMFILE=backend/Gemfile bundle install

# 2. Node dependencies
npm ci                      # the first time: npm install

# 3. Configuration
cp config/config.example.yml config/config.yml
chmod 600 config/config.yml

# 4. Database and start
scripts/migrate.sh
scripts/start_development.sh
```

**The order in step 1 is binding.** `bundle config set --local deployment true` requires an existing `Gemfile.lock` and otherwise stops with `The deployment setting requires a lockfile`. A release carries the lock file, a fresh working directory produces it only through `bundle lock`.

**`BUNDLE_GEMFILE` is required.** `Gemfile` and `Gemfile.lock` live in `backend/`, because they are replaced on update. Without the variable Bundler does not find them.

**`npm ci` runs in `project/`, not in `frontend/`.** From `project/tests/frontend/` a `frontend/node_modules` would not be resolvable, and every Vitest run would fail while resolving imports.

### 2.3 Addresses during development

| Service | Address |
|---|---|
| Vite development server | <http://127.0.0.1:5173> |
| Backend | <http://127.0.0.1:9292> |

Point the browser at the Vite server. During development `backend/public/` is empty, because the interface has not been built. Vite forwards `/api`, `/health` and `/version` to the backend.

---

## 3. Directory layout

```
project/
├── backend/          Application
│   ├── app.rb        Routes, protective layers, response format
│   ├── config.ru     Rack entry point
│   ├── version.rb    Version number, the single source
│   ├── services/     Domain logic, 27 modules
│   ├── migrations/   Schema steps, file name equals schema state
│   ├── locales/      Console texts, en.json only
│   └── public/       Built interface, produced by build
├── frontend/src/     Vue interface
│   ├── api/          Calls, error shape, session expiry
│   ├── state/        Application state
│   ├── views/        Screens
│   ├── components/   Reusable parts
│   ├── locales/      Five language files
│   └── util/         Rendering, normalisation, helpers
├── doc/              Manuals in English and German
├── img/              Screenshots used by the README
├── scripts/          17 launcher pairs, logic in scripts/lib/
├── tests/            Minitest, Vitest, Playwright, vectors, fixtures
├── examples/         Sample package for the empty state
├── config/           config.example.yml as the source of all defaults
├── README.md         Entry point, also as README.de.md
└── LICENSE.md        MIT licence
```

`project/` corresponds to the installation directory of a release. `project/backend/` corresponds to `app/` there.

---

## 4. Tests

```bash
scripts/run_tests.sh                  # backend and frontend
scripts/run_tests.sh --e2e            # plus the browser tests
scripts/run_tests.sh --only=backend   # a single suite
```

| Level | Tool | Subject |
|---|---|---|
| Backend | Minitest | Domain logic, interface, scripts |
| Frontend | Vitest | Components and state |
| Browser | Playwright | End-to-end flows in Chromium, Firefox, WebKit and at 360 px width |

Test runs write their output to `test-results/`. That directory lies outside `project/` so that a test run can never touch the development database.

### 4.1 Principles

**A new set of tests that is entirely green on its first run is verified by mutation.** The code under test is deliberately damaged and the suite is checked for a failure. If everything stays green, the test does not verify what it claims to.

**What is checked is the effect, not the setting.** A test comparing a configured value says nothing about whether that value has any effect.

**Every test case produces what it needs itself.** The browser tests share one instance. A case relying on state produced by another case is not runnable on its own.

**A fake server is itself under test.** If it answers differently from the real server, the test verifies a fiction.

### 4.2 Checks against project documents

Three checks compare the source against the internal project documents rather than testing the application. Those documents are not part of this repository.

| Check | Purpose |
|---|---|
| `acceptance_protocol_test` | Every acceptance criterion has a recorded result |
| `test_case_register_test` | Every test case number used in the source is a defined one |
| `plan_packages_test` | Every work package appears in the project overview |

**In a clone these nine cases skip**, with the reason stated in the output. They need files that are not published. A skipped run is expected and is not a failure.

### 4.3 Language checks

| Check | Subject |
|---|---|
| `one_language_test` | No German domain values in the source |
| `console_language_test` | No German strings in console output |

The two are separate because they look for different sets of words. The word list of the second check does not prove that a string is English. It catches the words it carries, and the file says so.

---

## 5. Architecture

### 5.1 Interface

`backend/app.rb` holds the routes and the protective layers. The domain logic lives entirely in `backend/services/`. A route accepts a request, checks permissions through `Access` and calls a service module.

The `before` block processes every request in a fixed order:

1. Assign a request identifier, so that a later error can be traced to one call
2. Enforce HTTPS where configured
3. Set security headers
4. Resolve the session
5. Determine the language (11.7)
6. Refresh the session cookies
7. Check CSRF on writing requests
8. Check rate limits
9. Trigger the clean-up run if none has happened on this calendar day

The language is determined before any refusing check, so that a refusal is also phrased in the right language.

The last step is the only one not belonging to the request. `sweep_if_due` marks the day as done before doing the work, so concurrent requests do not trigger it more than once. An instance without traffic does not clean up.

### 5.2 Permissions

`services/access.rb` is the single place where access is decided. For a combination of action, role, ownership and visibility it returns a verdict.

The visibility condition exists as an SQL fragment with a value list, not merely as a check on a loaded record. Only that way can it be placed inside the search query. Filtering afterwards would compute paging and ranking over rows the caller may not see.

### 5.3 Response format

Responses are JSON. Errors carry a machine-readable code, not merely a sentence. The interface branches on the code and produces the text itself, so the same error appears in every language.

Timestamps follow ISO 8601 with a time zone. Ruby's default rendering of a `Time` does not, and is reformatted.

---

## 6. Database and migrations

### 6.1 Structure

Migrations are Ruby files under `backend/migrations/`. The file name carries the schema state. They are read with `load` and leave no process-wide state behind.

Ruby rather than SQL, because the triggers need the normalisation expression produced by `services/normalization.rb`.

Database settings are attached to Sequel's `after_connect`, not applied once. Otherwise connections opened later would have no foreign key enforcement.

### 6.2 Waiting on write conflicts

`PRAGMA busy_timeout` stalls the entire process, because SQLite waits in C without releasing Ruby's global lock. What is used instead is `busy_handler_timeout` of the sqlite3 gem.

The order is binding: setting a handler clears `busy_timeout`, and a later `PRAGMA busy_timeout` reinstates the blocking handler.

### 6.3 Full-text index

Search uses FTS5 with an external content table. Mirror columns hold the normalised values and are maintained by triggers.

Rebuilding through the FTS5 `rebuild` command refills the index from the content table and destroys the normalisation in the process. The rebuild therefore goes through the mirror columns.

On deletion the index needs the **old** indexed values. Otherwise orphaned terms remain, which `integrity-check` reports when given an argument but not without one.

### 6.4 Migration 006

The most recent migration introduces `prompts.title_sort` and creates an index over `(workspace_id, title_sort)`. It works in eight steps:

1. Empty the full-text index
2. Add the column
3. Drop six triggers
4. Compute the values for every row
5. Create the index
6. Recreate the triggers, now including `title_sort`
7. Refill the full-text index
8. Verify the result

The index has to be emptied before the recomputation, because it holds the old values of the mirror columns.

A trigger cannot have an expression as its body. The six triggers are therefore replaced rather than altered.

Unlike migration 005, migration 006 does not need foreign key enforcement switched off. 005 rebuilds tables, and a `DROP TABLE` fires `ON DELETE CASCADE` when enforcement is on.

Sorting uses `title_sort`. `ORDER BY title` would produce a byte order in which capitals precede lower case and everything accented comes last.

---

## 7. Rendering pipeline

The pipeline runs in five steps. The numbering below is the one used throughout the source:

| Step | Action |
|---|---|
| 1 | Body of the prompt |
| 2 | Substitute variables |
| 2b | Resolve escapes |
| 3 | Apply keywords, by position and sort order |
| 4 | Normalise whitespace |

Step 2b is deliberately a step of its own. Combined with step 2 the order of the two rules would not be observable from outside, and the JavaScript implementation could choose a different one.

### 7.1 Two implementations, one test bed

The pipeline exists in Ruby and in JavaScript and has to compute identical results. This is secured through 34 shared vectors in `tests/vectors/rendering.json`, which both sides check against the same file.

A divergence between the two counts as blocking. No further work package is started while one exists.

### 7.2 Character set of placeholders

| Environment | Expression |
|---|---|
| Ruby | `[[:alpha:]][[:alnum:]_]{0,39}` |
| JavaScript | `[\p{L}][\p{L}\p{N}_]{0,39}` with the `u` flag |

Unicode letters are permitted so that placeholders such as `{{prénom}}` or `{{año}}` are recognised. Previously they were left in place literally and were not even reported as unknown variables, because they were not recognised as variables at all.

**The `u` flag is mandatory in JavaScript.** Without it `\p{L}` means four literal characters, with no error.

Sequences not matching the rule are reported through `rejected_keys`. Widening the character set moves the boundary, it does not remove it.

The case table lives in `tests/fixtures/placeholder_cases.json` and is read by both sides.

---

## 8. Search and normalisation

### 8.1 Normalisation

`services/normalization.rb` produces the rule both as a Ruby function and as an SQL expression, from the same table. A registered SQL function would not be usable, because FTS5 and the sqlite3 command line do not know it.

Umlauts and their transcriptions map onto the base vowel, so that `Größe`, `Groesse` and `Grosse` coincide.

`lower()` in SQLite works on ASCII only. Capital letters with diacritics therefore appear explicitly in the replacement table.

Input is composed with `unicode_normalize(:nfc)`. Without that step a search term with decomposed characters finds nothing, not even a prompt stored the same way.

### 8.2 Search terms

A search term passed to FTS5 unprocessed can abort the query. The preparation normalises, splits into alphanumeric runs, quotes each word as a prefix expression and joins them. Characters between the words are discarded.

If no word remains, the text filter is dropped. An empty result would be wrong, because a search box containing only punctuation would then empty the library.

Ranking uses `bm25` with different weights for title, description, body and tags. `bm25` returns negative values, and smaller values are better matches.

Highlighting works on the original text, not through the FTS5 functions. Those return the normalised text, and a position in it cannot be mapped back unambiguously.

---

## 9. Sign-in and protective layers

### 9.1 Passwords

Argon2id through the argon2 gem. `m_cost` is the base-2 logarithm of the memory in KiB, so 64 MiB corresponds to the value 16.

For an unknown identifier a full pass is computed against a fixed comparison value. That value is a constant. Were it produced on demand, the first attempt would be measurably slower and the identical error message worthless.

The lockout check comes **before** the password check. Otherwise every attempt by a locked-out caller would cost a full pass, and the limit would act as an amplifier.

### 9.2 Sessions

A session is carried by a random token of which the database stores only the SHA-256 hash. No session secret exists in the configuration.

Both cookies carry an expiry equal to `session.idle_timeout_days` and are refreshed on every authenticated request. Without an expiry the browser discards them on exit, and the promised 14 days could not be kept.

The CSRF cookie expires at the same time. If it did not outlive the session cookie, every writing request would fail with 403.

### 9.3 Rate limits

| Limit | Value | Counted per |
|---|---|---|
| Writing requests | 120 per minute | Session |
| Import and export | 5 per minute | User |

The second limit counts per user, because it would otherwise grow with every additional sign-in. It also covers the account data export, although that is a `GET`.

The import preview is exempt. It writes nothing, and the prescribed workflow requires a preview before every import.

### 9.4 Source address

What is evaluated is the actual address. `X-Forwarded-For` is considered only if the immediate sender appears in `server.trusted_proxies`, and is then read from the right.

`REMOTE_ADDR` is used, not `request.ip`. Rack decides for itself which addresses count as proxies, and that assumption is not the operator's configuration.

---

## 10. Configuration

`services/configuration.rb` reads `config/config.yml` and places `config/config.example.yml` underneath as defaults. The template is therefore not merely documentation but the single source of the default values.

An invalid value stops startup and names the key and the expected range. All problems are collected, not only the first.

Unknown keys stop startup as well. This is stricter than necessary and is listed in chapter 14.

The validation rules live on the class and are also used by the values editable in the administration area. A value typed into a form is therefore judged by the same measure as one written into the file.

`locale` is checked for its shape, not against the files in `backend/locales/`. The interface languages travel in the bundle, where the server cannot count them.

---

## 11. Translations

### 11.1 Division

| Location | Contents |
|---|---|
| `frontend/src/locales/*.json` | Interface, five languages |
| `backend/locales/en.json` | Console output, English only |

The console speaks English only. Those lines are read by whoever installs and operates an instance, including on machines that are not their own. They are pasted into search engines and bug reports.

The interface's `en.json` is the base table. Every other language is laid over it, so that a missing key is answered from there.

### 11.2 Choosing the language

| Call | Checks |
|---|---|
| `I18n.offered?(code)` | The shape only, such as `de` or `pt-BR` |
| `I18n.available?(code)` | Whether a console file exists for it |

The split came out of a defect. A single check against the server files also decided the language of the interface, whose files live in the bundle. A French browser received English, a French profile choice was discarded, and `locale: fr` prevented startup.

The server passes on the most specific language tag. Resolving it is the browser's job through `resolve()`, which tries the exact code, then the primary subtag, then the base table.

Language names come from `Intl.DisplayNames`. Romance languages write their own name in lower case, so the first letter is raised with `toLocaleUpperCase(code)`.

---

## 12. Interface

### 12.1 Layout

| Directory | Contents |
|---|---|
| `api/client.js` | Base path, CSRF header, error shape, handling of expired sessions |
| `state/` | Application state through `reactive`, without a state library |
| `router/` | Routes and guards |
| `views/` | Screens |
| `components/` | Frame, loading, empty and error states, overlays |

`/health` and `/version` sit beside the interface and are called without a prefix. The server treats them the same way, so the state of an instance can be queried without knowing which generation of the API it speaks.

The two endpoints differ in access. `/health` is open, because monitoring has to reach it without an account. `/version` requires a sign-in, because the version of a service is not public information.

### 12.2 Expired session

If a session expires during input, an overlay opens above the screen. The entries are kept, and the interrupted request is repeated with the same body after signing in again.

The repetition disables the resume path for itself. Otherwise the overlay would open endlessly.

### 12.3 Screens are imported statically

Screens are not loaded per route. The bundle stays well below the promised limit, and lazy loading would cost an extra round trip per screen.

---

## 13. Building and releasing

```bash
scripts/build.sh                 # builds the interface and produces the archives
scripts/build.sh --skip-tests    # without the preceding test run
```

`build` runs the test suite and stops on failures. The test status is written into the `VERSION` file of the archive.

### 13.1 Two archive shapes

| Shape | Contents | Purpose |
|---|---|---|
| Platform-specific | with `vendor/bundle` | Installation without internet access, bound to one platform and one Ruby series |
| Universal | without libraries | Any platform, libraries fetched during installation |

Without the second shape no package for Windows could be built from a Linux machine.

Only the universal shape is published. The platform-specific one is produced by operators themselves through `package`, on a machine of the kind they need.

### 13.2 Reproducibility

The archives are written by the build itself rather than handed to `tar` and `zip`. Reproducibility is a property of the writer, and `zip` is absent on many servers. `SOURCE_DATE_EPOCH` is honoured.

### 13.3 What is not shipped

| Component | Reason |
|---|---|
| `node_modules/` | Result of building |
| `frontend/`, `tests/`, `release/` | Sources and results of development |
| `config/config.yml` | Describes the building machine, including the networks it trusts |
| Ruby itself | Installed through the operating system |
| `build`, `run_tests`, `start_development` | Require Node or the test directory |

`run_tests` is the most important of these. Without `tests/` it would find no test file, skip every suite and report at the end that all tests that ran have passed.

### 13.4 Version number

The version number lives in `backend/version.rb` and nowhere else. From there it reaches the `/version` endpoint, the `VERSION` file of the archive and the archive name.

It does not belong in `config.yml`. That file is deliberately not replaced on update, and a version number in it would remain in place permanently after the first update.

---

## 14. Deliberate design choices

The following arrangements may look like oversights. Each is intentional, and the reason is given.

| Choice | Reason |
|---|---|
| `project/` is the installation directory during development, with `config/` and `data/` inside it | Paths then resolve during development exactly as they do in a release |
| The npm workspace has its `package.json` in `project/`, not in `frontend/` | From `project/tests/frontend/` a `frontend/node_modules` would not be resolvable, and every Vitest run would fail while resolving imports |
| Unknown keys in `config.yml` stop startup | Otherwise a typing mistake stays without effect and without a message |
| `test-results/` lies outside `project/` | A test run then cannot touch the development database |
| `puma.rb` derives the application directory from its own location | The directory is called `backend/` during development and `app/` in a release |
| `puma.rb` applies the defaults from the template | Otherwise a value missing from `config.yml` would have no fallback |
| The Vite server is fixed to `127.0.0.1:5173` with `strictPort` | Without it Vite moves to another port when 5173 is taken, and the browser then reaches nothing |
| `project/package.json` carries `"type": "module"` | The Playwright configuration files are ES modules |
| `build` writes the archives itself rather than calling `tar` and `zip` | Reproducibility is a property of the writer, and `zip` is absent on many servers |
| `build` produces two archive shapes | Without the universal shape no package for Windows could be built from a Linux machine |
| `build`, `run_tests` and `start_development` are not shipped | They require Node or the test directory, neither of which is part of a release |
| The application serves the built interface itself | Without it a reload on an application-side address would answer with the JSON 404 of an API |

An arrangement of this kind that is not listed here counts as a defect.
