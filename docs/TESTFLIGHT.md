# Shipping Atlas to TestFlight

`just testflight` builds the iOS app, audits it and uploads it to App Store
Connect. It is the studio's `ship-ios` pipeline; this file is Atlas's part of
it.

```sh
just testflight                    # build, audit, upload
just testflight --no-upload        # build and audit, keep the build local
just testflight --allow-branch     # build from a branch that is not origin/main (trials only)
```

## Before you ship

The pipeline's gate is `just check`: the core package builds, the core tests
run, and both platforms build. The end-to-end flows are **not** in the gate —
they need a booted simulator and the live TfL feed — so run them yourself
first:

```sh
just ui-test-ios     # XCUITest: tap a camera dot, expect its monitor
just e2e             # Maestro: the camera tap and the place search
```

Both write their proof into `docs/design/`.

## What the pipeline does

| Stage | What Atlas does |
| --- | --- |
| Preflight | The tree must be clean and HEAD must be `origin/main` (or `--allow-branch`). The build comes from a commit. |
| Checks | `just check`. |
| Build | `scripts/ship.sh` generates the Xcode project from `project.yml`, archives Release for `generic/platform=iOS`, and stamps a timestamp build number (`date +%y%m%d%H%M`), so every upload is higher than the last. |
| Audit | The bundle is `io.ponti.atlas.ios`, the archived build number is the one this ship stamped, `ITSAppUsesNonExemptEncryption` is NO, the archive is **not** signed with a development identity, and nothing shaped like a secret key is in the app. A failed audit is a hard stop. |
| Symbols | Atlas has no crash reporter yet, so its dSYMs ride along with the archive upload (`uploadSymbols` in `scripts/ExportOptions-testflight.plist`). |
| Upload | `xcodebuild -exportArchive` with the upload destination. Xcode must be signed in, or an App Store Connect API key must be available. |

## What it needs on this machine

- **An Apple Distribution certificate.** The keychain holds only
  `Apple Development` and a macOS `Developer ID` certificate, so the archive
  comes out development-signed and the audit stops. Create the distribution
  certificate in Xcode (Settings ▸ Accounts ▸ Manage Certificates ▸ Apple
  Distribution) and archive again.
- **An App Store Connect app record** for `io.ponti.atlas.ios`, with the
  marketing version from `project.yml` (`MARKETING_VERSION`).
- **A signed-in Xcode account**, or an App Store Connect API key.

## The Mac app

`just testflight` ships the iOS app only. The Mac app goes out through the
`macos-app-distribution` skill, not through TestFlight.

## The repository

- The Xcode project is generated from `project.yml` and is gitignored: a fresh
  checkout runs `just setup` (or `just gen`) before it builds.
- The skills are project-installed and pinned: `skills-lock.json` holds
  `ship-ios` and `studio-dev` under `.agents/skills/`. `just studio-update`
  restores the locked set; `just studio-check` fails when a skill is missing.
