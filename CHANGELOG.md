# Changelog

All notable changes to this project are recorded here. The format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and the project uses [semantic versioning](https://semver.org/spec/v2.0.0.html).

## [1.0.1] - 2026-09-03

Service operation on Windows and Linux, found and fixed after 1.0.0 was published. Everything here was measured on the target systems, not inferred.

### Fixed

- **The Windows service could not be registered at all.** A Ruby script cannot be a Windows service on its own, and the wrapper was given a file the system cannot execute. It is now started through an entry point of its own, which resolves the server from the bundle rather than from the `PATH`. Whether Ruby is installed for one user or for the whole machine no longer makes a difference.
- **The Linux system service ran as `root`.** It wrote its process id file into a directory belonging to the installing account, and did not remove that file when killed. The owner could then no longer replace it, so every later start bound the port and died immediately afterwards, leaving neither the service nor the portable mode usable. The system service now runs as the account that owns the installation.
- **The last step of the installation left the application running on Windows.** It started the server through a wrapper and stopped only the wrapper, so the port stayed occupied.
- **The unit file was invalid for installation paths containing a space.** systemd splits `Environment=` on whitespace, so such a path arrived cut in half.
- **A version stated in more than one place could drift.** The version is now stated once and checked against every repetition of it.
- **The commit line of the delivered `VERSION` file always read `unknown`.** It was looked up one directory above the repository.
- **A non-interactive installation refused a question whose default it had just displayed.** It now uses that default. A question without a default still refuses.

### Changed

- Bundler is named as a requirement, together with the version the lock file asks for. On Debian and Ubuntu it is not part of `ruby-full`.
- Removing a user service reports that lingering stays switched on, and names the command that undoes it. It is a machine-wide setting that may have been set for something else.

## [1.0.0] - 2026-09-03

First public release.

- **Library** with full-text search across title, description, body and tags. Spelling variants are resolved, so `Größe` is found by typing `groesse` or `grosse`. Filtering by tag, restriction to favourites, sorting by relevance, date of change or title.
- **Variables**: placeholders in double curly braces become form fields with a label, a default value, a required flag and a kind, among them single line, multiline, selection list and number. Unicode letters are permitted.
- **Live preview** during input. Browser and server produce identical output, verified against 34 shared test vectors.
- **Keywords**: reusable blocks of text placed before or after a prompt, switchable individually while using a prompt.
- **Workspaces** with the roles `viewer`, `editor`, `admin` and `owner`, plus instance administration. Prompt visibility is set independently as `private`, `workspace` or `instance`.
- **Change history**: trash with 30 days of retention, undo of the last change, revisions per prompt with a configurable count and minimum retention.
- **Import and export** as JSON and Markdown, lossless in both directions, with a preview before anything is written. Every collision is decided in the preview and named in the report afterwards. A prompt whose title already exists can be skipped, copied or overwritten. A keyword whose name already exists can be skipped or overwritten, with the existing and the incoming definition shown side by side. Command line tools for moving a whole instance.
- **Five interface languages**: German, English, French, Italian, Spanish.
- **Operation** on Linux and Windows, in the foreground or as a system service. Installation, migration, backup, restore and measurement are covered by scripts.
- **Security**: Argon2id password storage, sessions carried by a random token stored as a hash, CSRF protection on writing requests, rate limits on sign-in attempts and on import and export, and an audit log that cannot be altered through the interface.
