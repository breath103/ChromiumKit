# CLAUDE.md

Notes for agents working in this repo.

## Start here

Read [`README.md`](README.md) to understand what this repo is and how it's put
together before making changes.

## Running the example app from a sandbox / headless session

Unit tests run fine (ad-hoc signing, no GUI). But a sandboxed session **cannot
codesign** (securityd boundary) and **cannot answer GUI/TCC prompts**, so signed
builds and app-hosted **UI** tests (XCTest "automation mode") will fail or hang
there — hand those to the user's login session. The example sets
`useMockKeychain` so CEF's "Chromium Safe Storage" prompt never blocks a launch;
don't re-add signing to chase that specific prompt. See
[`documents/code-signing.md`](documents/code-signing.md).

## Pre-PR health check (mandatory)

Before opening a pull request, run:

```
./scripts/lint.sh
```

Commit any resulting changes as part of the PR. See
[Linting](README.md#linting) in the README for what the script does and how to
set up the tools.
