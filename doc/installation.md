**English** · [Deutsch](installation.de.md)

# Prompt Atelier: Installation and Operation

| | |
|---|---|
| **Version** | 1.2 |
| **Date** | 2026-08-30 |
| **Describes** | Prompt Atelier 1.0.0 |
| **Audience** | Operators setting up and running an installation |
| **Not covered** | Working on the source. See `development.md` |

This guide covers the complete path from the requirements to a running instance. For looking up individual tasks during day-to-day operation, use `operations.md`.

---

## Contents

1. [Preparation](#1-preparation)
2. [Installation](#2-installation)
3. [Operating modes](#3-operating-modes)
4. [Configuration](#4-configuration)
5. [Core concepts](#5-core-concepts)
6. [Backup and restore](#6-backup-and-restore)
7. [Updating](#7-updating)
8. [Running behind a reverse proxy](#8-running-behind-a-reverse-proxy)
9. [Troubleshooting](#9-troubleshooting)
10. [Script overview](#10-script-overview)
11. [Security properties](#11-security-properties)
12. [Limits](#12-limits)

---

## 1. Preparation

### 1.1 Sizing

The application is designed for instances of up to 50 users and 20,000 prompts. It needs no database server. The data lives in a single SQLite file.

The performance of the target machine can be measured before putting it into service:

```bash
scripts/measure.sh
```

The script creates its own test installation with its own directory, database and port, and writes a report. The existing installation is left untouched.

### 1.2 The archive

One platform-independent archive is published per release, as `.tar.gz` and as `.zip`:

```
promptatelier-1.0.0-universal.tar.gz
promptatelier-1.0.0-universal.zip
```

It contains the application with the interface already built, but **no Ruby libraries**. The installer fetches those on its first run, guided by the bundled lock file `Gemfile.lock`.

**The absence of an archive with precompiled libraries is deliberate.** Precompiled libraries are binaries produced on somebody else's machine. Running them means trusting whoever built them. Fetched on the target machine instead, they come from the official source and can be verified against the lock file.

The target machine therefore needs internet access. For machines without it, see [section 1.4](#14-installation-without-internet-access).

> **Note:** On Windows, use the `.zip` archive.

### 1.3 Checking the requirements

```bash
scripts/check_environment.sh --operation-only     # Linux
scripts\check_environment.bat --operation-only    # Windows
```

The script checks Ruby, Bundler and the Ruby libraries, and reports every missing requirement together with the matching installation command for the detected system. Notes marked yellow do not affect operation. Only errors marked red prevent it.

| Environment | Requirement |
|---|---|
| Linux | Ruby 3.3 or newer |
| Windows | Ruby 3.3 or newer, installed as RubyInstaller with DevKit |
| Both | 500 MB of disk space, 1 GB of memory, one free TCP port |

Disk space, memory and whether the intended port is free are **not** checked by the script. Those three have to be verified by hand. A port already in use surfaces only in the last step of the installation, and does so with a clear message.

DevKit is required on Windows because several libraries are compiled during installation. Without it the installation stops in the second step with a compiler message.

Node.js is not needed to run the application. It serves only to build the interface, which ships already built.

### 1.4 Installation without internet access

An archive including the libraries can be produced yourself. This requires a machine **of the same kind** with internet access, meaning the same operating system and the same Ruby series.

1. Install as usual on the connected machine:

   ```bash
   scripts/install.sh
   ```

2. Turn that installation into an archive:

   ```bash
   scripts/package.sh /path/to/target
   ```

3. Transfer the archive to the target machine, unpack it and run `scripts/install.sh` there.

The resulting archive contains the libraries and needs no internet access on the target machine. **Configuration and data of the source installation are not carried over.** The target machine asks for an administrative account of its own during installation.

The name of the archive states the platform and the Ruby series, for example `promptatelier-1.0.0-x86_64-linux-gnu-ruby3.3.0.tar.gz`. It is usable only on machines of that kind.

---

## 2. Installation

```bash
tar -xzf promptatelier-1.0.0-universal.tar.gz     # Linux
cd promptatelier-1.0.0-universal
scripts/install.sh
```

On Windows, unpack the ZIP archive using Explorer and run this inside the unpacked directory:

```
scripts\install.bat
```

The script performs seven steps:

| Step | Action |
|---|---|
| 1 | Check the requirements. Anything missing is named together with its installation command |
| 2 | Install the Ruby libraries, unless they are already present |
| 3 | Create `config/config.yml` from the template, with file mode `0600` |
| 4 | Create the database schema |
| 5 | Create the first user account with administrative rights |
| 6 | Set up the operating mode |
| 7 | Start the instance and query the health endpoint |

The address of the instance is printed at the end.

### 2.1 Unattended installation

If every required value is passed as a switch, the installation runs without asking anything:

```bash
scripts/install.sh \
  --port=9292 \
  --mode=portable \
  --admin-name="Anna Example" \
  --admin-email=anna@example.test \
  --admin-password='a-long-passphrase'
```

> **Warning:** Values must be given with an equals sign. A spelling with a space, such as `--port 9292`, is not evaluated. The installation then uses the default value. See [chapter 10](#10-script-overview).

If no terminal is available and a required value is missing, the script names the missing value and stops.

### 2.2 Running it again

The installer may be run more than once. It detects what is already in place and says so. An existing `config/config.yml` is left unchanged. A second administrative account is not created. Schema steps are not applied and backups are not made.

---

## 3. Operating modes

Four operating modes are available:

| Mode | Use | Automatic start | Elevated rights |
|---|---|---|---|
| Linux, portable | Single workstation, removable media, evaluation | no | no |
| Linux, service | Continuous operation on a server | yes | only for the system service |
| Windows, portable | Single workstation, evaluation | no | no |
| Windows, service | Continuous operation | yes | yes |

In portable mode the entire installation directory can be moved, copied or placed on removable media. All paths are resolved relatively.

```bash
scripts/start_portable.sh            # start in the foreground, Ctrl+C stops it
scripts/service_install.sh           # Linux: user service
scripts/service_install.sh --system  # Linux: system service, elevated rights required
scripts/service_uninstall.sh         # remove the service, data is kept
```

The examples in this guide use the Linux form. On Windows the file of the same name with the `.bat` extension applies, so `scripts\backup.bat` instead of `scripts/backup.sh`.

### 3.1 Linux user service

Setting up a user service also sets `loginctl enable-linger`. Without it the service starts only when the user logs in, which after a server reboot may mean not at all.

The call requires elevated rights. If it fails, the service is set up regardless, the limitation is reported, and the command to run later is printed.

### 3.2 Windows service

The service mode requires `tools\nssm.exe`. A Ruby script cannot be a Windows service on its own, so a wrapper registers it as one.

**NSSM is not part of the archive.** It is a separate program under its own licence, available from <https://nssm.cc/download>. Download it, take `nssm.exe` from the `win64` directory of the archive and place it in the `tools` directory of the installation.

The scripts were developed against **NSSM 2.24**, the release offered on that page. Other versions are not tested. The download page also offers a prerelease. Use the release.

> **Warning:** Registering a service needs an administrator. Open the Start menu, type `cmd`, choose **Run as administrator**, then run `scripts\service_install.bat` from there. Started without those rights, the wrapper reports no error of its own but the service is not created, and the script says so.

A Windows service outlives the directory it was installed from. If an earlier attempt left one behind, the script says so and asks for `scripts\service_uninstall.bat` first.

The service starts `scripts\lib\service_run.rb`, which sets its own environment. Once registered it writes to `data\logs\service.log`. That file holds the reason when the service exists but does not stay up.

If the file is absent, the installer says so and prints a command that registers a scheduled task instead. That command has to be run by hand in a command prompt started as an administrator.

A task registered that way starts the application at system start, but not after a crash. It therefore replaces a service only in part.

---

## 4. Configuration

The entire configuration lives in `config/config.yml`. The file is created in full during installation.

### 4.1 Behaviour on invalid values

1. If a value is missing, the default from `config/config.example.yml` applies.
2. An invalid value prevents startup. The message names the key and the expected range.
3. An unknown key name also prevents startup. A typing mistake becomes visible instead of remaining without effect.

### 4.2 Where each setting belongs

| Kind | Examples | Location | Takes effect |
|---|---|---|---|
| Operating values | Address, port, paths, trusted proxies, HTTPS enforcement, logging | `config/config.yml` only | after the next start |
| Product values | Self-registration, sign-in limits, lockout period, retention periods | `config/config.yml` **and** the administration area | immediately in the administration area |

> **Warning:** The eleven product values exist in both places, and the two are not separate. Once a value has been saved in the administration area, the saved value takes precedence permanently. Any later change to the same line in `config/config.yml` then has no effect, not even after a restart.

The administration area shows for every value whether it comes from the file or was saved. A saved value can be changed there but not reset to the file value. To keep the file as the leading source, do not change these values in the administration area.

### 4.3 File permissions

`config/config.yml` is created with mode `0600`. The file contains the list of trusted proxies. Whoever can change that list can lift the limit on sign-in attempts and have arbitrary addresses written into the audit log.

If the permissions are wider, the application prints a note at startup and starts regardless. Windows has no equivalent to these permissions.

The file contains no session secret. Sessions are carried by a random token of which the database stores only the hash. To lock a user out, block their account in the administration area. Their sessions end immediately.

### 4.4 Self-registration

| Value | Behaviour |
|---|---|
| `off` | Accounts are created in the administration area only. This is the delivered state |
| `approval` | Users can register and are approved afterwards |
| `open` | Users can register and are signed in immediately |

---

## 5. Core concepts

### 5.1 Prompt

A text with a title, description, tags and a visibility. There is no separate object type for templates. If the text contains placeholders, the prompt acts as one.

### 5.2 Variable

A placeholder in double curly braces creates a form field. Each variable can carry a label, a default value, a required flag and a kind (single line, multiline, selection, number).

Unicode letters, digits and the underscore are permitted, up to 40 characters. The first character must be a letter. Character sequences that do not follow this rule are reported as rejected placeholders when rendering.

A leading backslash suppresses the substitution. `\{{topic}}` renders as `{{topic}}`, and the backslash itself disappears.

### 5.3 Keyword

A reusable block of text with a fixed position, either before or after the prompt. The order of several keywords is set by a sort value.

### 5.4 Workspace

A workspace governs membership and access. Every user has a personal workspace, and shared workspaces are created for collaboration. The roles are `viewer`, `editor`, `admin` and `owner`. In addition there is the right to administer the instance.

The visibility of a prompt is set independently:

| Visibility | Access |
|---|---|
| `private` | the owner only |
| `workspace` | every member of the workspace |
| `instance` | every signed-in user |

There is no folder structure. Membership is governed by the workspace, and finding things again by tags and full-text search.

### 5.5 Recovering content

| Situation | Approach |
|---|---|
| Prompt overwritten by accident | The "undo last change" function |
| Prompt deleted | Trash, kept for 30 days |
| An older state is needed | Only by repeating "undo last change" or by restoring a backup |

> **Note:** A list of all revisions with free choice of a state does not exist in this release. Every call of "undo last change" takes the most recent stored state and consumes it. How many states are kept follows `retention.revisions_per_prompt` and `retention.revisions_min_days`.

---

## 6. Backup and restore

```bash
scripts/backup.sh                  # creates a backup under data/backups/
scripts/restore.sh                 # lists the available backups
scripts/restore.sh <file>          # restores a backup, asking first
scripts/restore.sh <file> --yes    # without asking, for automated procedures
```

> **Warning:** Stop the application before restoring. `restore` checks the configured port and stops as long as the instance answers.

A file name without a path is resolved against `data/backups/`. A backup from anywhere else requires an absolute path. Calling the script without an argument lists the most recent backups and is the easiest way to learn a file name.

> **Warning:** Do not copy the database file by hand. In WAL mode part of the data lives in side files. A manual copy is unusable or incomplete without any integrity check reporting it. The backup script produces a consistent file while the application runs.

A backup should include:

| Directory or file | Reason |
|---|---|
| `data/backups/*.db` | the backups themselves |
| `config/config.yml` | the operating values of the installation. Without it a restored instance starts with the defaults |
| `data/logs/` | only where logs must be retained |

`restore` reads the given backup completely before any data is overwritten. An unusable file therefore causes no data loss. The script also creates a safety copy of the previous data before replacing it and prints its path at the end.

After a restore every user is signed out. Sessions are held in the database and are reset to the state of the backup.

---

## 7. Updating

1. Create a backup: `scripts/backup.sh`
2. Stop the service
3. Replace `app/`, `scripts/`, `doc/`, `README.md` and `LICENSE` with the new release
4. Update the schema: `scripts/migrate.sh`
5. Start the service
6. Query the health endpoint `/health`

The directories `config/` and `data/` are left untouched.

`migrate` creates a backup of its own before every schema step. Calling `scripts/migrate.sh --status` prints the pending steps without changing anything.

If the schema state and the application version do not match, the application does not start and names the required step.

---

## 8. Running behind a reverse proxy

In the delivered state the application accepts connections over `127.0.0.1` only. Two options exist for access from the network:

1. Put a reverse proxy in front that terminates TLS, and leave `server.host` unchanged. This is the recommended arrangement.
2. Set `server.host` to `0.0.0.0`. The application is then reachable over the network without encryption.

Example configurations for nginx and Apache are in `doc/examples/`.

Two values already present in `config/config.yml` need to be **changed**:

```yaml
server:
  host: "127.0.0.1"            # leave unchanged
  port: 9292                   # leave unchanged
  base_url: "https://…"        # the address the proxy is reachable at
  trusted_proxies: ["127.0.0.1"]   # previously []

security:
  force_https: true            # previously false
```

> **Warning:** The blocks `server` and `security` already exist in the file. Appending them a second time makes YAML discard the first block without any message. `host`, `port` and `base_url` are then missing, are filled in from the template, and the instance runs on a different port after the restart.

Over HTTPS the session cookie carries the `Secure` attribute because of the protocol alone. `force_https` adds the redirect from HTTP to HTTPS and sets `Secure` even when the application itself is addressed over HTTP. For calls over `localhost`, `127.0.0.1` and `::1` neither the redirect nor the attribute applies. Testing on the machine itself therefore does not show the setting.

> **Warning:** Without an entry in `trusted_proxies` the `X-Forwarded-For` header is not evaluated. Every request then appears with the address of the proxy, and the limit on sign-in attempts per address applies to all users together. An entry that does not belong to your own infrastructure lets any caller claim a false address.

---

## 9. Troubleshooting

| Observation | Cause | Approach |
|---|---|---|
| Startup stops and names a configuration key | invalid value or typing mistake in `config.yml` | the message names the key and the expected range |
| Startup stops with `EADDRINUSE` | port in use | configure another port or stop the process holding it |
| Startup stops with a schema message | schema state and application version do not match | `scripts/migrate.sh` |
| Instance not reachable from other machines | bound to `127.0.0.1` | see [chapter 8](#8-running-behind-a-reverse-proxy) |
| Everybody signed out after a restore | sessions are held in the database | sign in again |
| No sign-in possible at all | administrative account blocked or password unknown | see section 9.1 |

### 9.1 Emergency access

There is no password reset by email. If no sign-in is possible any more, this is the way back:

```bash
scripts/reset_admin_password.sh                       # the only administrative account
scripts/reset_admin_password.sh anna@example.test     # a specific account
scripts/reset_admin_password.sh --generate            # the password is generated
```

Without an address the script works only if exactly one account holds instance administration rights. If there are several, it prints their addresses and changes nothing.

Every run ends all sessions of the account, is recorded in the audit log, and forces the account to choose its own password at the next sign-in.

The route requires access to the machine and to the installation directory, not merely to the network.

### 9.2 Error messages and logs

For server-side errors the interface shows a general message together with an identifier. Paths, queries and stack traces appear in the log under `data/logs/` only. The identifier locates the matching log entry.

---

## 10. Script overview

All scripts live under `scripts/` and exist once as `.sh` and once as `.bat`. The launchers contain no logic of their own. A return value of `0` means the run succeeded.

> **Warning:** The spelling of values is not uniform. `install` and `measure` expect an equals sign, `seed_demo` a space. With the exception of `measure`, unknown switches are passed over without a message. If a value appears to have no effect, check the spelling first.

For `reset_admin_password` the address is not a switch but a free argument. It is recognised by the `@` it contains.

| Script | Main switches | Purpose |
|---|---|---|
| `check_environment` | `--operation-only`, `--all`, `--skip-gems` | check the requirements |
| `install` | `--port=`, `--mode=`, `--admin-name=`, `--admin-email=`, `--admin-password=` | first installation |
| `start_portable` | `--no-backup` | start in the foreground |
| `service_install` | `--system` | set up the service |
| `service_uninstall` | `--system` | remove the service |
| `migrate` | `--status` | update the database schema |
| `backup` | `--no-rotate` | create a backup |
| `restore` | `<file>`, `--yes` | restore a backup |
| `reset_admin_password` | `[address]`, `--generate` | emergency access |
| `seed_demo` | `--remove`, `--yes`, `--email <address>` | add or remove sample content |
| `package` | `[target directory]`, `--zip` | turn this installation into an archive |
| `export_all` | `[file]` | write the instance as a migration file |
| `import_all` | `<file>` | load a migration file into an empty instance |
| `measure` | `--prompts=`, `--runs=`, `--serve` | measure performance on the target machine |

The complete reference is in `operations.md`.

`build`, `start_development` and `run_tests` are not shipped. They belong to the development environment.

### 10.1 Moving to another instance

| Method | Use |
|---|---|
| `backup` and `restore` | complete transfer of the data including accounts and the audit log |
| `export_all` and `import_all` | transfer of the content into a newly installed instance |

The migration file contains no passwords. Every account receives a one-time password on import, printed once. `import_all` works only on an instance without existing accounts.

---

## 11. Security properties

| Area | Implementation |
|---|---|
| Passwords | Argon2id. Plain text is neither stored nor logged nor returned in any response |
| Sessions | Random token, stored in the database as a hash only. Cookie attributes `HttpOnly` and `SameSite=Strict`, plus `Secure` behind HTTPS |
| Writing requests | A CSRF token is verified, otherwise status code 403 |
| Sign-in attempts | At most 5 per account and 20 per address within 15 minutes |
| Import and export | At most 5 operations per minute and user |
| Audit log | Records security-relevant operations and cannot be altered through the interface |
| Error messages | Contain no paths, queries or stack traces |

The application passes no data to third parties and needs no external service at runtime. Instance administration covers accounts and workspaces, but not read access to other people's prompt content. Access is possible only through a membership, which is recorded in the audit log.

---

## 12. Limits

| Field or quantity | Limit |
|---|---|
| Title | 200 characters |
| Description | 1,000 characters |
| Prompt body | 100,000 characters |
| Variables per prompt | 50 |
| Options per variable | 100 |
| Tags per prompt | 20 |
| Keywords per workspace | 200 |
| Keywords active at once | 20 |
| Model note | 200 characters |
| Default value per variable | 2,000 characters |
| Name of a tag or keyword | 40 characters |
| Body of a keyword | 5,000 characters |
| Name of a workspace | 100 characters |
| Import file | 10 MB |
| Rendered prompt | 200,000 characters |
| Writing requests | 120 per minute and session |

The limits are enforced on the server. When one is exceeded the operation is refused and the limit is named in the message.
