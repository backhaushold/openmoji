# ADR-0011: Manual signing with per-target profiles in project.yml

- **Status:** Proposed
- **Date:** 2026-10-02

## Context
Sagelet signs Release archives by passing `CODE_SIGN_STYLE=Manual`, `CODE_SIGN_IDENTITY` and a single `PROVISIONING_PROFILE_SPECIFIER` on the `xcodebuild` command line. Command-line build settings apply to **every target**, so with an app extension the extension would be signed with the app's profile and fail. Sagelet's runbook explains why it uses manual signing: CLI archives with automatic signing want a development profile, which needs registered devices.

## Decision
- Set `CODE_SIGN_STYLE: Manual`, `CODE_SIGN_IDENTITY: Apple Distribution` and a per-target `PROVISIONING_PROFILE_SPECIFIER` ("OpenMoji App Store", "OpenMoji Messages App Store") in each target's **Release** config in `project.yml`.
- The command line passes only `CURRENT_PROJECT_VERSION` and the `--keychain` code-sign flag. Debug stays automatic.
- `ExportOptions.plist` maps both bundle IDs to their profiles.

## Alternatives
- **Automatic signing with `-allowProvisioningUpdates` and the ASC key.** Cloud-managed certificates and no profile files, but it has the device-registration issue Sagelet hit, and the result is less predictable from the CLI.
- **Per-target xcconfig files.** Equivalent, but one more file type when XcodeGen already expresses it.

## Consequences
- Profile names appear in `project.yml` and `ExportOptions.plist`; renaming a profile means two edits.
- Profiles and the certificate expire yearly; the runbook records the dates (open question: alert on these too?).
