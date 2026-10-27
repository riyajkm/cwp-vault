# How this project is built

CWP Vault is built by a maintainer working with Claude Code and a fixed set of AI sub-agents.
This file says who does what, how a change moves from idea to release, and the rules every change
follows. Human contributors follow the same flow (see `CONTRIBUTING.md`).

## Branches, versions, changelog

- `main` = released code only. Every merge to `main` is a release, tagged `vX.Y.Z`.
- `dev` = integration branch. All work lands here first.
- Feature branches `feat/<topic>`, `fix/<topic>`, `docs/<topic>` → pull request into `dev`.
- **Semantic Versioning.** `0.x` while the design settles; `1.0.0` when backup + status + restore are proven.
- **Conventional Commits** (`feat:`, `fix:`, `docs:`, `test:`, `ci:`, `chore:`, `refactor:`, `security:`).
  One logical step per commit.
- **`CHANGELOG.md`** follows [Keep a Changelog](https://keepachangelog.com). Every PR adds a line under
  `## [Unreleased]`. A release moves those lines under the new version with the date.
- Release: PR `dev → main` → tag `vX.Y.Z` → GitHub Release with the changelog section.

## Roles (agents)

| Stage | Agent | Job |
|---|---|---|
| Plan | Maintainer (Opus) | Splits a milestone into tasks, owns architecture, security decisions, server actions, final review |
| Architecture | `agency-software-architect` | Reviews module boundaries, config format, repo layout |
| Threat model | `agency-security-architect` | Trust boundaries: root engine ↔ PHP module ↔ customer module ↔ S3; key handling |
| Engine (bash) | `agency-devops-automator` | restic wrappers, cron, locking, retries, Contabo tuning |
| CLI UX | `agency-developer-tooling-engineer` | `vault` command design, help text, exit codes, errors |
| CWP module (PHP) | `backend-developer` | Admin module pages, AJAX endpoints, CSRF, input whitelist |
| Module UI | `frontend-developer` | Match CWP's admin look; status table, restore wizard |
| Tests | `qa-tester`, `agency-test-automation-engineer` | bats tests for the engine, restore smoke tests, edge cases |
| Run checks | `checker` | shellcheck, bats, `php -l`, CI status — reports numbers only |
| Security review | `agency-appsec-engineer`, `agency-secrets-credential-engineer` | Code review for injection, path traversal, secret leaks |
| Pen test | `agency-penetration-tester` | Admin module and AJAX reachable only with an admin session (test VM only) |
| Performance | `agency-performance-benchmarker` | Throughput vs Contabo limits, memory on small VPS |
| Reliability | `agency-sre` | Alerts, heartbeat, test-restore schedule, failure modes |
| Docs | `agency-technical-writer`, `agency-dx-engineer` | README, install guide, restore guide, provider guides, first-run experience |
| Release gate | `agency-reality-checker`, `agency-code-reviewer` | Evidence-based go/no-go before every release |
| Launch | `agency-trend-researcher`, `agency-growth-hacker`, `agency-reddit-community-builder`, `agency-developer-community-builder`, `agency-twitter-engager`, `agency-linkedin-content-creator`, `agency-content-creator`, `agency-seo-specialist`, `agency-pr-communications-manager`, `agency-social-media-strategist` | Where CWP users are, launch posts, demo content, SEO for "CWP backup S3", community replies. Drafts only — a human posts. |

## The flow for one task

```
plan task (maintainer)
  → branch feat/<topic> from dev
  → build (role agent; brief = goal, files, rule, how to test)
  → tests written/updated (qa-tester)
  → checks green (checker: shellcheck, bats, php -l)
  → review (maintainer reads the diff; security agents for risky parts)
  → CHANGELOG line under [Unreleased]
  → PR → dev (CI must pass) → merge
```

Server-touching steps (installing on a live server, cron, unlocking CWP's admin folder) are run by
the maintainer only, after the owner says yes. Agents never see storage keys or passwords.

## Milestone gates

1. **Stage 0 (v0.1.0):** research findings written before any engine code.
2. **Engine (v0.2.0):** three successful nightly runs on the reference server.
3. **Installer (v0.3.0):** clean install and uninstall on a throwaway CWP VM.
4. **Module (v0.4.0) and Restore (v0.5.0):** security review + pen test on the VM.
5. **v1.0.0:** reality-checker sign-off, docs complete, launch kit ready.

## Rules

- No secrets, IPs, hostnames, account names or customer data in the repo, issues or commits. Use `example.com`, `alice`, `bucket-name`.
- Never build shell commands from user input; pass arguments as arrays and whitelist actions.
- Every write-capable endpoint: admin session + CSRF token.
- Prefer restic's built-ins over custom code.
