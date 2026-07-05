# Code signing for HelloChromium (stop the repeated permission prompts)

## The problem

The example app is **ad-hoc signed** by default — `project.yml` sets
`CODE_SIGN_IDENTITY: "-"`. Ad-hoc signing produces a *different* code identity
on every rebuild. macOS keys these to the signing identity:

- **Keychain ACLs** — CEF's "Chromium Safe Storage" prompt, where you click
  *Always Allow*.
- **TCC grants** — the XCTest automation/accessibility permission, the
  "developer tools" permission.

Because the identity changes each build, every grant you make is bound to a
binary that no longer exists next build, so macOS **re-prompts forever**. If the
Keychain or XCTest prompt keeps reappearing "every few minutes," this is why.

The fix is a **stable signing identity**. Grant the prompts once; they persist
across rebuilds because the identity no longer changes.

> **Note on the CEF Keychain prompt specifically.** HelloChromium starts CEF
> with `ChromiumConfiguration.useMockKeychain = true`, which makes Chromium skip
> the macOS Keychain for safe storage — so the "Chromium Safe Storage" prompt
> doesn't appear at all, regardless of signing. The signing setup below is
> therefore mainly for the **XCTest automation / accessibility** and
> **developer-tools** TCC prompts, which mock-keychain does not affect.

## Nothing here is committed

The repo default stays ad-hoc (`"-"`) so a fresh clone and CI build with **zero
setup**. The stable identity is a purely **local, per-developer opt-in** via the
`CHROMIUMKIT_SIGN_IDENTITY` environment variable. No cert name, team id, or
machine-specific value is ever committed.

## One-time local setup

### 1. Create a stable identity

Either use your **Apple Development** certificate (sign into Xcode → Settings →
Accounts with your Apple ID; it generates one), or create a **self-signed**
identity — no Apple account needed:

```sh
scripts/make-signing-identity.sh          # creates "ChromiumKit Local"
```

That script generates a self-signed code-signing certificate, imports it into
your login keychain, sets the key's partition list so `codesign` can use it
without prompting, and trusts it for code signing. It prompts once for your
macOS login password. Verify:

```sh
security find-identity -v -p codesigning   # should list "ChromiumKit Local"
```

### 2. Point the build at it

Copy the template and set the identity name:

```sh
cp .env.example .env
# edit .env →  CHROMIUMKIT_SIGN_IDENTITY="ChromiumKit Local"
```

`.env` is gitignored. **Loading it is your shell's job, not the script's** — use
[direnv](https://direnv.net) (`direnv allow`), source it (`set -a; source .env;
set +a`), or just `export CHROMIUMKIT_SIGN_IDENTITY=...` in your profile.
`scripts/cli.swift` only *reads* `CHROMIUMKIT_SIGN_IDENTITY` from the environment
and forwards it to `xcodebuild` as `CODE_SIGN_IDENTITY` (`signingArgs()`).

### 3. Grant the prompts one last time

Run any build/test that launches the app:

```sh
scripts/cli.swift ui SessionRestoreUITests
```

The CEF "Chromium Safe Storage" Keychain prompt and the XCTest automation prompt
appear **once more** — grant them (*Always Allow*). Because the app is now signed
with the stable identity, the grants stick and later runs are silent.

## CI

CI (`.github/workflows/ci.yml`) builds ad-hoc by default and does not run the
app, so it needs no identity. The `CHROMIUMKIT_SIGN_IDENTITY` value is plumbed
through the xcodebuild step from the repo variable of the same name, defaulting
to `"-"`:

```yaml
env:
  CHROMIUMKIT_SIGN_IDENTITY: ${{ vars.CHROMIUMKIT_SIGN_IDENTITY || '-' }}
```

To actually sign in CI (e.g. to run UI tests there later), set the repo variable
**and** add a step that imports the certificate from a secret into a temporary
keychain before the build — the runner has no keychain identity otherwise. That
import is intentionally not wired up here; ad-hoc is the right default for the
current build-only CI.

## Why a self-signed cert is enough

`codesign` signs with an untrusted-then-trusted self-signed identity just fine;
trust only matters for *verification*. What macOS cares about for persisting
grants is that the identity is **stable and consistent** across rebuilds — which
a self-signed cert in your keychain provides. An Apple Development cert works
identically; it's just sourced from your Apple account.
