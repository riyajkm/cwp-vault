# Contributing

Thanks for helping. The full process is in [docs/WORKFLOW.md](docs/WORKFLOW.md); the short version:

## Branches

- `main` holds released code only. Every merge to `main` is a tagged release.
- `dev` is the integration branch.
- Branch from `dev` as `feat/<topic>`, `fix/<topic>` or `docs/<topic>` and open a pull request into `dev`.
- Releases are a pull request from `dev` to `main`, then a `vX.Y.Z` tag.

## Commits

Use [Conventional Commits](https://www.conventionalcommits.org): `feat:`, `fix:`, `docs:`, `test:`, `ci:`,
`chore:`, `refactor:`, `security:`. One logical step per commit. No DCO sign-off is required.

## Changelog

Every PR adds one line under `## [Unreleased]` in `CHANGELOG.md` ([Keep a Changelog](https://keepachangelog.com)).

## Before you open a PR

```sh
shellcheck $(git ls-files '*.sh')
bats tests/
find . -name '*.php' -print0 | xargs -0 -r -n1 php -l
```

## No secrets or real data

Never put secrets, storage keys, IPs, hostnames, account names, emails or customer data in code, tests,
issues, logs or commits. Use `example.com`, `alice` and `bucket-name`.

## Reporting bugs

Open an issue with the bug report form. Include the CWP version, OS, storage provider and redacted logs.
Security problems go through [SECURITY.md](SECURITY.md), not public issues.
