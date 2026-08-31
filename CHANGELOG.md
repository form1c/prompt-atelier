# Changelog

All notable changes to this project are recorded here. The format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and the project uses [semantic versioning](https://semver.org/spec/v2.0.0.html).

## [1.0.0] - 2026-08-31

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
