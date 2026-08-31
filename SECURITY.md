# Security Policy

## Supported versions

| Version | Supported |
|---|---|
| 1.0.x | yes |

## Reporting a vulnerability

Please do not report security issues through public issues, pull requests or discussions.

Use GitHub's private reporting instead: on the repository page open **Security**, then **Report a vulnerability**. The report stays private until a fix is available.

Please include:

- the version, taken from the account menu of the running instance or from the `VERSION` file of the release
- the operating mode, meaning portable or service, and the operating system
- what you observed and how to reproduce it
- the effect you consider possible

## What to expect

This is a project maintained in spare time. There is no guaranteed response time and no service level agreement. Reports are read and answered as time allows.

## Scope

Prompt Atelier is self-hosted. Each installation is operated by whoever runs it, and there is no service operated by the project.

In scope are defects in the application, in the delivered scripts and in the documented configuration.

Out of scope are:

- issues that depend on an installation being configured against its own documentation, for example `server.host` set to `0.0.0.0` without a reverse proxy
- vulnerabilities in third-party libraries, unless the application uses them in a way that creates the issue. Report those to the library concerned
- findings that require an account with instance administration rights, since that role has full administrative access by design

## Security properties of the application

The manual `doc/operations.md` describes the security-relevant configuration keys. The developer manual `doc/development.md` describes password storage, session handling, rate limits and the audit log.
