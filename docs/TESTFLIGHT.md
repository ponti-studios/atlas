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
| Upload | `xcodebuild -exportArchive` with the upload destination. Exports sign manually against the installed `Atlas iOS Distribution` profile; the upload authenticates with the App Store Connect API key (below). |

## What it needs on this machine

All four are in place as of the first upload; this is the checklist for a new
machine.

- **An Apple Distribution certificate** with its private key in the login
  keychain: `Apple Distribution: Ponti & Co, LLC (3QHJ2KN8AL)`. The key pair is
  generated locally (CSR → portal → import), so the private key never leaves
  the machine; a backup of the key, the CSR and the issued certificate lives in
  `~/Downloads/atlas-signing/`.
- **The App Store provisioning profile** `Atlas iOS Distribution`
  (`3QHJ2KN8AL.io.ponti.atlas.ios`, App Store type), installed into
  `~/Library/MobileDevice/Provisioning Profiles/`. Device builds sign with it
  manually (`CODE_SIGN_IDENTITY[sdk=iphoneos*]` in `project.yml`); simulator
  builds stay automatic because they need no profile.
- **An App Store Connect app record** for `io.ponti.atlas.ios` (the public name
  is *Atlas Geo Archive* — plain *Atlas* is taken on the App Store), with the
  marketing version from `project.yml` (`MARKETING_VERSION`).
- **An App Store Connect API key** with the Admin role, at
  `$ATLAS_ASC_KEY_DIR/AuthKey_REDACTED-KEY-ID.p8` (issuer
  `REDACTED-ISSUER-ID`). The key lives outside the repository
  and is never committed. `scripts/ship.sh` reads it from
  `$ATLAS_ASC_KEY_DIR`, and `$ATLAS_ASC_KEY_ID` / `$ATLAS_ASC_ISSUER_ID`
  override the defaults.

Do not fall back to Xcode's account session for the upload: it expires and the
export then fails with *"Your session has expired. Please log in."*

## Testers

The **Internal** group holds the account holder only, with automatic
distribution on: every uploaded build is assigned to it and appears in the
TestFlight app without a manual step. Use *Internal ▸ Builds* to see what a
group can install.

## The Mac app

`just testflight` ships the iOS app only. The Mac app goes out through the
`macos-app-distribution` skill, not through TestFlight.

## The repository

- The Xcode project is generated from `project.yml` and is gitignored: a fresh
  checkout runs `just setup` (or `just gen`) before it builds.
- The skills are project-installed and pinned: `skills-lock.json` holds
  `ship-ios` and `studio-dev` under `.agents/skills/`. `just studio-update`
  restores the locked set; `just studio-check` fails when a skill is missing.
