**English** · [Deutsch](operations.de.md)

# Prompt Atelier: Operations Manual

| | |
|---|---|
| **Version** | 2.1 |
| **Date** | 2026-08-30 |
| **Describes** | Prompt Atelier 1.0.0 |
| **Audience** | Operators during day-to-day operation |
| **Not covered** | The complete set-up path. See `installation.md`. Working on the source. See `development.md` |

This manual is a reference. It describes every setting, every script and every message on its own. The connected path from the requirements to a running instance is in `installation.md`.

---

## Contents

1. [Directory layout](#1-directory-layout)
2. [Configuration reference](#2-configuration-reference)
3. [Script reference](#3-script-reference)
4. [Recurring tasks](#4-recurring-tasks)
5. [Messages and faults](#5-messages-and-faults)
6. [Logs](#6-logs)

---

## 1. Directory layout

| Directory | Contents | On update |
|---|---|---|
| `app/` | Application, libraries, built interface | replaced |
| `config/` | `config.yml` and `config.example.yml` | left unchanged |
| `data/` | Database, backups, logs | left unchanged |
| `scripts/` | Operating scripts | replaced |
| `doc/` | Installation guide, operations manual, developer manual, and under `doc/examples/` the reverse proxy templates | replaced |
| `README.md`, `LICENSE` | Overview and license text | replaced |
| `tools/` | Helper programs, on Windows `nssm.exe` | left unchanged |

All paths are resolved relative to the installation directory. The directory can be moved.

---

## 2. Configuration reference

Every setting lives in `config/config.yml`. If a value is missing, the default from `config/config.example.yml` applies. An invalid value or an unknown key name prevents startup and is named in the startup message.

### 2.1 `server`

| Key | Default | Meaning |
|---|---|---|
| `host` | `127.0.0.1` | Address the application accepts connections on. Use `0.0.0.0` only behind a reverse proxy |
| `port` | `9292` | TCP port, 1 to 65535 |
| `base_url` | `http://localhost:9292` | Full address the instance is reachable at |
| `trusted_proxies` | `[]` | List of addresses or networks whose forwarding headers are evaluated |

### 2.2 `database`

| Key | Default | Meaning |
|---|---|---|
| `path` | `data/promptatelier.db` | Path of the database file |
| `wal` | `true` | Write-ahead logging. Required for consistent backups while the application runs |

### 2.3 `session`

| Key | Default | Meaning |
|---|---|---|
| `idle_timeout_days` | `14` | Period without activity after which a session ends |
| `absolute_timeout_days` | `90` | Maximum lifetime of a session regardless of activity |

### 2.4 `security`

| Key | Default | Meaning |
|---|---|---|
| `argon2.memory_mib` | `64` | Memory used per password check |
| `argon2.iterations` | `3` | Number of passes |
| `argon2.parallelism` | `1` | Number of parallel lanes |
| `login_attempts_per_account` | `5` | Failed attempts per account within the lockout window |
| `login_attempts_per_ip` | `20` | Failed attempts per source address within the lockout window |
| `lockout_minutes` | `15` | Length of the lockout window |
| `force_https` | `false` | Redirects HTTP to HTTPS and sets the `Secure` cookie attribute. Over HTTPS the cookie carries `Secure` anyway. For calls over `localhost`, `127.0.0.1` and `::1` neither the redirect nor the attribute applies |
| `registration` | `off` | Self-registration: `off`, `approval` or `open` |
| `registrations_per_hour` | `5` | Maximum number of new accounts per source address and hour |

Raising the Argon2 values lengthens every sign-in. Changes affect newly set passwords only.

> **Warning:** `registration`, `registrations_per_hour`, `login_attempts_per_account`, `login_attempts_per_ip` and `lockout_minutes` can also be set in the administration area. Once one of them has been saved there, the saved value takes precedence over the file permanently. A later change to the same line then has no effect.

### 2.5 `backup`

| Key | Default | Meaning |
|---|---|---|
| `keep` | `14` | Number of backups kept. Older ones are removed on the next run |

Backups created before a schema change are not counted here.

### 2.6 `retention`

| Key | Default | Meaning |
|---|---|---|
| `revisions_per_prompt` | `50` | Revisions kept per prompt |
| `revisions_min_days` | `90` | Minimum retention of revisions in days |
| `trash_days` | `30` | Retention of deleted prompts in the trash |
| `audit_months` | `12` | Retention of audit log entries in months |
| `audit_max_entries` | `200000` | Maximum number of audit log entries |
| `login_attempts_days` | `7` | Retention of recorded sign-in attempts |

These values can also be set in the administration area and take effect there immediately. A value saved there takes precedence over the file permanently.

### 2.7 `logging`

| Key | Default | Meaning |
|---|---|---|
| `level` | `info` | `debug`, `info`, `warn` or `error` |
| `path` | `data/logs` | Directory of the log files |
| `rotate_mb` | `20` | Size at which a log file is rotated |
| `keep_files` | `5` | Number of log files kept |

### 2.8 Language of the instance

Unlike the preceding sections this one describes no block, but a single key at the **top level** of the file:

```yaml
locale: "de"
```

| Key | Default | Meaning |
|---|---|---|
| `locale` | empty | Interface language for the whole instance. Empty means the language setting of the browser applies |

Five languages are shipped:

| Code | Language |
|---|---|
| `de` | German |
| `en` | English |
| `fr` | French |
| `it` | Italian |
| `es` | Spanish |

The setting establishes the default for the instance. Users can choose a different language in their profile.

> **Note:** Only the **shape** of the code is checked at startup, for example `pt-BR`. A well-formed code without a matching language file is accepted, but the interface then appears in English.

### 2.9 File permissions

`config/config.yml` is created with mode `0600`. If the permissions are wider, the application prints a note at startup and starts regardless, since Windows has no equivalent.

The file contains no session secret. What is worth protecting is `server.trusted_proxies`: whoever can change that list can lift the limit on sign-in attempts and have arbitrary addresses written into the audit log.

---

## 3. Script reference

Every script lives under `scripts/` as `.sh` and as `.bat`. The launchers contain no logic of their own. The details below apply to both forms. A return value of `0` means the run succeeded.

Every script operates on the installation it belongs to, regardless of the current working directory.

> **Warning:** The spelling of values is not uniform. `install` and `measure` expect an equals sign, `seed_demo` a space. With the exception of `measure`, unknown switches are passed over without a message.

### 3.1 `check_environment`

Checks the requirements and names the installation command for each missing item on the detected system.

| Switch | Effect |
|---|---|
| none | The scope follows the detected form of installation |
| `--operation-only` | Only what is needed to run the application |
| `--all` | Additionally the build tools Node.js and npm |
| `--skip-gems` | Without checking the Ruby libraries |
| `--no-heading` | Without the heading, for calls from other scripts |

### 3.2 `install`

First installation in seven steps.

| Switch | Effect |
|---|---|
| `--port=<number>` | Set the port |
| `--mode=portable` \| `--mode=service` | Set the operating mode |
| `--admin-name=<name>` | Name of the first account |
| `--admin-email=<address>` | Address of the first account |
| `--admin-password=<password>` | Password of the first account |

If every value is passed, the installation runs without asking. Without a terminal and without complete values the script names the missing one and stops.

On a repeated run the existing configuration, database and administrative account are left unchanged.

### 3.3 `start_portable`

Starts the application in the foreground. Ctrl+C stops it and creates a backup on the way out.

| Switch | Effect |
|---|---|
| `--no-backup` | Without the backup on exit |

### 3.4 `service_install` and `service_uninstall`

Sets the application up as a service or removes it. Configuration and data are kept in both cases.

| Switch | Effect |
|---|---|
| none | Linux: user service. Windows: service through NSSM |
| `--system` | Linux: system service, elevated rights required |

### 3.5 `migrate`

Brings the database schema up to the state of the application and creates a backup beforehand.

| Switch | Effect |
|---|---|
| `--status` | Prints the pending steps without changing anything |

### 3.6 `backup`

Creates a consistent backup under `data/backups/` while the application runs.

| Switch | Effect |
|---|---|
| `--no-rotate` | Older backups are kept |

### 3.7 `restore`

Restores a backup. The file is read completely before any data is overwritten. Before replacing anything the script creates a safety copy of the previous data and prints its path at the end.

| Argument | Effect |
|---|---|
| none | Lists the most recent backups and states the call syntax |
| `<file>` | File name or path of the backup. A name without a path is resolved against `data/backups/`. A backup from anywhere else requires an absolute path |
| `--yes` | Without asking |

> **Warning:** Stop the application first. The script checks the configured port and stops as long as the instance answers.

### 3.8 `reset_admin_password`

Sets a new password for an account holding instance administration rights. All sessions of the account are ended, the operation is recorded in the audit log, and the account has to choose its own password at the next sign-in.

| Argument | Effect |
|---|---|
| `<address>` | The account concerned. Without it, permitted only if exactly one administrative account exists |
| `--generate` | The password is generated and printed once |

### 3.9 `seed_demo`

Adds sample content in the workspace "Beispiele". This script changes the existing installation and asks before doing so.

| Argument | Effect |
|---|---|
| `--remove` | Removes the added content, identified by a marker |
| `--yes` | Without asking |
| `--email <address>` | Owner of the created prompts |
| `--workspace <name>` | A different workspace name |

Content outside the created workspace is never touched. `--remove` also recognises renamed sample prompts and leaves your own content in the same workspace alone.

### 3.10 `package`

Turns the existing installation into an archive for a target system without internet access. Configuration and data are not carried over.

| Argument | Effect |
|---|---|
| `[target directory]` | Where to put it. Without it, beside the installation directory |
| `--zip` | ZIP archive only, instead of ZIP and TAR |
| `--keep-tree` | The unpacked intermediate directory is kept |

### 3.11 `export_all` and `import_all`

Transfer a whole instance to a newly installed one.

| Script | Argument | Effect |
|---|---|---|
| `export_all` | `[file]` | Without it, a file with a timestamp is created under `data/` |
| `import_all` | `<file>` | Loads the file. No further switches exist |

The migration file contains no passwords and no audit log. Every account receives a one-time password, printed once. `import_all` works only on an instance without existing accounts and stops otherwise.

### 3.12 `measure`

Measures performance on the target machine. The script creates a test installation of its own, leaving the existing installation untouched. Unknown switches are refused.

| Switch | Default | Effect |
|---|---|---|
| `--prompts=<number>` | 5000 | Size of the test data set |
| `--runs=<number>` | 20 | Number of measurement runs per value |
| `--dir=<path>` | beside the installation | Where the test installation is created |
| `--keep` | off | The test installation is kept |
| `--serve` | off | The test installation stays running and reachable. Implies `--keep` |
| `--no-load` | off | Without the load measurement |
| `--reseed` | off | Discard an existing test data set and build it again |

The report is written as a Markdown file at `reports/measurement-<count>.md`, one level above the test installation.

### 3.13 Scripts that are not shipped

`build`, `start_development` and `run_tests` belong to the development environment and are not part of a release.

---

## 4. Recurring tasks

| Task | Suggested interval |
|---|---|
| Check that backups are being created | monthly |
| Practise restoring a backup | twice a year |
| Check the disk usage of `data/` | twice a year |
| Update to a new release | as available |

Trash, revisions, the audit log and recorded sign-in attempts are cleaned up automatically according to the values under `retention`. The clean-up run is triggered by the **first request of a calendar day** and runs at most once per day. An instance without traffic therefore does not clean up, and a failed run is retried the next day.

### 4.1 Updating

1. Create a backup: `scripts/backup.sh`
2. Stop the service
3. Replace everything listed as "replaced" in chapter 1: `app/`, `scripts/`, `doc/`, `README.md` and `LICENSE`
4. Update the schema: `scripts/migrate.sh`
5. Start the service
6. Query the health endpoint `/health`

### 4.2 Changing the operating mode

```bash
scripts/service_install.sh            # set up the service
scripts/service_uninstall.sh          # remove the service
scripts/start_portable.sh             # start in portable mode
```

A change is possible at any time. Configuration and data are unaffected.

---

## 5. Messages and faults

### 5.1 The application does not start

| Message | Cause | Approach |
|---|---|---|
| Names a configuration key and an expected range | invalid value in `config.yml` | correct the value |
| Names an unknown key | typing mistake in the key name | check the spelling against `config.example.yml` |
| `EADDRINUSE` | port in use | configure another port or stop the process holding it |
| Schema state too old | pending schema steps | `scripts/migrate.sh` |
| Schema state too new | the database comes from a newer release | install the matching application version |
| Configuration file missing | incomplete installation | `scripts/install.sh` |

### 5.2 The application is not reachable

In the delivered state the application accepts connections over `127.0.0.1` only. For access from the network see `installation.md`, chapter 8.

### 5.3 Signing in is not possible

| Observation | Cause | Approach |
|---|---|---|
| An account is locked | the sign-in limit was exceeded | wait for the lockout window or unlock the account in the administration area |
| Everybody signed out after a restore | sessions are held in the database | sign in again |
| No administrative access left | password unknown or account locked | `scripts/reset_admin_password.sh` |

There is no password reset by email. Emergency access requires access to the machine and to the installation directory.

### 5.4 Error message with an identifier

For server-side errors the interface shows a general message together with an identifier. Paths, queries and stack traces appear in the log only. The identifier locates the matching entry.

---

## 6. Logs

| Log | Location | Contents |
|---|---|---|
| Application log | `data/logs/` | Errors and events with timestamp, user identifier and request identifier |
| Service log, user service | `journalctl --user -u promptatelier` | Output of the service on Linux |
| Service log, system service | `journalctl -u promptatelier` | For a service set up with `--system` |
| Audit log | Administration area of the application | Security-relevant operations, not alterable through the interface |

The scope and retention of the application log are controlled by `logging`, those of the audit log by `retention`.
