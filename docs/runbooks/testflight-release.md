# Runbook: TestFlight release (OpenMoji)

One-time Apple and Mac setup for the release lane, the expiry register, and a
short routine-release section. Design lives in the
[tech spec §12](../tech-spec.md#12-release-pipeline) and
[ADR-0010](../adr/0010-local-release-lane.md),
[ADR-0011](../adr/0011-manual-per-target-signing.md) and
[ADR-0015](../adr/0015-app-store-connect-api-tooling.md); this file is the
"how", the spec is the "why".

> **Status.** The one-time setup (section 2) is actionable now. The lane itself
> (`make testflight`, `scripts/release.sh`, `scripts/op-run.sh`,
> `scripts/asc.swift`, `release/ExportOptions.plist`, `release/.env.example`)
> does not exist yet; it lands with beads `openmoji-4kq` and `openmoji-2pq`.
> Section 4 describes it **as specified in §12.3**. When those beads land,
> reconcile section 4 with what was built.

## 1. Ground rules

- **Releases publish only from the local release Mac.** CI verifies and alerts;
  it never signs or uploads.
- **The App Store Connect (ASC) API key is never added to GitHub.** Not as an
  Actions secret, an Actions variable, an environment or organisation secret,
  a committed file, an issue or PR comment, or a bead comment. It lives only in
  1Password (section 2.5) and is read only by the local lane. The repo has no
  Actions secrets; workflows use only the built-in `GITHUB_TOKEN`
  ([ADR-0010](../adr/0010-local-release-lane.md)). If you believe CI needs ASC
  access, it does not: the expiry alert works from `build-*` tag dates
  ([§12.6](../tech-spec.md#126-ci-and-expiry-automation-github-actions)).
- The OpenAI key is unrelated to this runbook and lives only in the iPad's
  Keychain.
- Always use `rm -f` / `cp -f` in shell snippets; interactive aliases hang.

Constants used throughout:

| Thing | Value |
|---|---|
| Team ID | `AB5S94XWRQ` |
| App bundle ID | `com.backhaushold.openmoji` |
| Extension bundle ID | `com.backhaushold.openmoji.MessagesExtension` |
| App Group | `group.com.backhaushold.openmoji` |
| Profiles (names are exact) | `OpenMoji App Store`, `OpenMoji Messages App Store` |
| Signing keychain | `~/Library/Keychains/openmoji-signing.keychain-db` |
| 1Password vault | `OpenMoji` |
| ASC record name | `OpenMoji Family` (OQ-5; plain "OpenMoji" is taken) |
| Internal testing group | `Family` (name is exact; the lane refers to it) |

Mapping to [§12.2](../tech-spec.md#122-one-time-setup-runbook-docsrunbookstestflight-releasemd-written-in-m3)
and the human beads:

| §12.2 step | Section here | Bead |
|---|---|---|
| 1 App IDs with App Groups | 2.1 | `openmoji-t2m` |
| 2 App Store profiles | 2.2 | `openmoji-t2m` |
| 3 Signing keychain | 2.3 | `openmoji-t2m` |
| 4 ASC record and Family group | 2.4 | `openmoji-9yf` (group auto-distribution result also feeds `openmoji-ppj`, OQ-13) |
| 5 ASC API key | 2.5 | `openmoji-t2m` |

## 2. One-time setup (release Mac)

### 2.0 Prerequisites

1. Full **Xcode.app** is installed and selected (not just Command Line Tools):

   ```bash
   xcode-select -p
   # want: /Applications/Xcode.app/Contents/Developer
   sudo xcode-select -s /Applications/Xcode.app/Contents/Developer   # only if it printed /Library/Developer/CommandLineTools
   ```

2. Tools the lane calls (all Homebrew; no third-party SDKs are involved,
   NFR-7):

   ```bash
   brew install xcodegen gitleaks gh
   brew install --cask 1password-cli
   ```

3. 1Password CLI works against your account, and the `OpenMoji` vault exists:

   ```bash
   op vault list
   op vault create OpenMoji      # only if the vault is not listed
   ```

4. An **Apple Distribution certificate** for team `AB5S94XWRQ` exists with its
   private key on this Mac. Tech spec assumption A7 is that the certificate
   already used for the team's other app can sign OpenMoji too (profiles are
   per App ID, certificates per team). Check:

   ```bash
   security find-identity -v -p codesigning
   # want a line like: "Apple Distribution: <Your Name> (AB5S94XWRQ)"
   ```

   If there is none: Xcode, Settings, Accounts, select the team, **Manage
   Certificates**, **+**, **Apple Distribution**. If A7 turns out false (the
   certificate cannot be reused), create a second Apple Distribution
   certificate the same way and note it in the register (section 3).

### 2.1 Register the App Group and both App IDs (§12.2 step 1)

Apple Developer portal, Certificates, Identifiers & Profiles, **Identifiers**
(<https://developer.apple.com/account/resources/identifiers/list>). Do this
**before** generating profiles; a profile generated earlier does not carry the
group and must be regenerated ([ADR-0006](../adr/0006-app-group-and-keychain-group.md)).

1. **+**, choose **App Groups**, Continue. Description `OpenMoji`, Identifier
   `group.com.backhaushold.openmoji`. Register.
2. **+**, choose **App IDs**, Continue, choose **App**, Continue.
   - Description `OpenMoji`.
   - Bundle ID: **Explicit**, `com.backhaushold.openmoji`.
   - Capabilities: tick **App Groups** only. Continue, Register.
   - Open the new App ID again, click **Configure** (or Edit) beside App
     Groups, select `group.com.backhaushold.openmoji`, Continue, Save.
3. Repeat step 2 for the extension: Description `OpenMoji Messages`, explicit
   Bundle ID `com.backhaushold.openmoji.MessagesExtension`, App Groups ticked
   and configured with the same group.

Keychain sharing needs no portal capability. It is the `keychain-access-groups`
entitlement under the team prefix (`$(AppIdentifierPrefix)com.backhaushold.openmoji.shared`),
declared in the entitlements files, not here.

Verify: reopen both App IDs and confirm App Groups is enabled and lists
`group.com.backhaushold.openmoji`.

### 2.2 Create and install the App Store profiles (§12.2 step 2)

Portal, **Profiles** (<https://developer.apple.com/account/resources/profiles/list>).
For each row below: **+**, under Distribution choose **App Store Connect**,
Continue, pick the App ID, Continue, tick the Apple Distribution certificate
from 2.0, Continue, enter the profile name **exactly** as shown, Generate,
Download.

| App ID | Profile name |
|---|---|
| `com.backhaushold.openmoji` | `OpenMoji App Store` |
| `com.backhaushold.openmoji.MessagesExtension` | `OpenMoji Messages App Store` |

These two names are referenced by `project.yml` (per-target Release settings,
[§12.5](../tech-spec.md#125-signing-settings-in-projectyml-adr-0011)) and
`release/ExportOptions.plist` ([§12.4](../tech-spec.md#124-releaseexportoptionsplist)).
Renaming a profile means editing both.

Install each downloaded `.mobileprovision` by opening it (double-click, or
`open <file>`). Current Xcode stores installed profiles in
`~/Library/Developer/Xcode/UserData/Provisioning Profiles/` (older Xcode used
`~/Library/MobileDevice/Provisioning Profiles/`). Confirm both are installed
and read their expiry dates:

```bash
for p in "$HOME/Library/Developer/Xcode/UserData/Provisioning Profiles"/*.mobileprovision; do
  name=$(security cms -D -i "$p" | plutil -extract Name raw -o - -)
  exp=$(security cms -D -i "$p" | plutil -extract ExpirationDate raw -o - -)
  echo "$name  expires $exp"
done
```

Both `OpenMoji App Store` and `OpenMoji Messages App Store` must appear.
**Record the expiry dates in the register (section 3).** No device
registration is needed for App Store distribution.

### 2.3 Dedicated signing keychain (§12.2 step 3)

Why a separate keychain: the lane runs unattended, and the login keychain
cannot be unlocked without typing your macOS password. A dedicated keychain
holding only the distribution identity, with a random password stored in
1Password and no auto-lock, can be unlocked by the lane
([§12.3 step 5](../tech-spec.md#123-make-testflight-sequence-scriptsreleasesh-via-scriptsop-runsh)).

Shell variables for this section (nothing secret in them):

```bash
KC="$HOME/Library/Keychains/openmoji-signing.keychain-db"
KC_PW_REF="op://OpenMoji/openmoji-signing-keychain/password"
```

1. **Generate the keychain password in 1Password** (it never appears on screen
   or in history):

   ```bash
   op item create --category=Password --title=openmoji-signing-keychain \
     --vault=OpenMoji --generate-password='letters,digits,symbols,32'
   ```

   The `op://` reference above is the name this runbook fixes for the item.
   `release/.env.example` (lane bead) must reference the same path.

2. **Create the keychain** with that password. `security` warns that `-p` is
   "insecure" because the value is visible in the process list for an instant;
   acceptable for a one-time step on a single-user Mac. Omit `-p ...` to be
   prompted instead.

   ```bash
   security create-keychain -p "$(op read "$KC_PW_REF")" "$KC"
   ```

3. **Turn off auto-lock.** Passing neither `-t <seconds>` (timeout) nor `-l`
   (lock on sleep) means "no timeout, never lock on sleep":

   ```bash
   security set-keychain-settings "$KC"
   security unlock-keychain -p "$(op read "$KC_PW_REF")" "$KC"
   security show-keychain-info "$KC"      # should report no-timeout
   ```

4. **Export the Apple Distribution identity as a `.p12`.** Use Keychain Access
   rather than `security export`: Keychain Access, the keychain that holds the
   certificate, My Certificates, "Apple Distribution: ...", right-click,
   **Export...**, format **Personal Information Exchange (.p12)**, save as
   `~/openmoji-dist.p12`, choose a throwaway export password. (`security export
   -t identities` exports **every** identity in a keychain, not just this one.)

5. **Import it with `codesign` authorised**, then **set the partition list**.
   Both are needed: `-T` adds `/usr/bin/codesign` to the key's access list and
   the partition list is what actually lets codesign use the key without a
   prompt. Omitting `-P` makes `security import` ask for the `.p12` password in
   a dialog, which keeps it out of shell history.

   ```bash
   security import ~/openmoji-dist.p12 -k "$KC" -T /usr/bin/codesign
   security set-key-partition-list -S apple-tool:,apple:,codesign: -s \
     -k "$(op read "$KC_PW_REF")" "$KC"
   ```

   (`-s` limits the change to keys that can sign. `-k` is marked deprecated in
   `man security`; leave it off to be prompted for the password instead.)

6. **Delete the temporary `.p12`**; the keychain now holds the only copy you
   need:

   ```bash
   rm -f ~/openmoji-dist.p12
   ```

7. **Verify non-interactively.** Lock the keychain, unlock it the way the lane
   will, and sign a throwaway binary. Success means no prompt and no
   `errSecInternalComponent`:

   ```bash
   security find-identity -v -p codesigning "$KC"        # 1 valid identity, Apple Distribution
   security lock-keychain "$KC"
   security unlock-keychain -p "$(op read "$KC_PW_REF")" "$KC"
   T=$(mktemp -d) && cp -f /bin/ls "$T/ls-test"
   codesign -f -s "Apple Distribution" --keychain "$KC" "$T/ls-test"
   rm -rf "$T"
   ```

Record the certificate expiry in the register (section 3):

```bash
security find-certificate -c "Apple Distribution" -p "$KC" | openssl x509 -noout -enddate -subject
```

### 2.4 App Store Connect record and the Family group (§12.2 step 4)

Needs ASC role Account Holder, App Manager or Admin, and the Account Holder
must have signed the latest agreement under Business
([Apple: Add a new app](https://developer.apple.com/help/app-store-connect/create-an-app-record/add-a-new-app/)).
Bead: `openmoji-9yf`.

1. **Create the record.** App Store Connect, Apps, **+**, **New App**.
   - Platforms: **iOS**.
   - Name: **`OpenMoji Family`** (OQ-5).
   - Primary language: your choice.
   - Bundle ID: choose `com.backhaushold.openmoji`. It only appears once 2.1
     is done.
   - SKU: any unique internal string, never shown to users (for example
     `openmoji-family`).
   - User Access: Full or Limited, your choice.
   - Create.

   "iPad only" is not a setting on this form. The record's platform is iOS and
   the supported device family comes from the uploaded build
   (`TARGETED_DEVICE_FAMILY = 2`, [ADR-0014](../adr/0014-ipad-only-device-family.md)).
   Nothing needs filling in beyond the record for TestFlight-only use.

2. **Create the internal group.** Open the app, **TestFlight** tab, click **+**
   beside **Internal Testing**, name it **`Family`**, tick **Enable automatic
   distribution**, Create
   ([Apple: Add internal testers](https://developer.apple.com/help/app-store-connect/test-a-beta-version/add-internal-testers/)).
   Automatic distribution is the primary REL-5 mechanism
   ([ADR-0015](../adr/0015-app-store-connect-api-tooling.md)); whether it
   behaves as hoped for CLI uploads is OQ-13 (`openmoji-ppj`). Record the
   outcome there. If it does not work, `asc.swift ensure-in-group` covers it
   and nothing here changes.

3. **Add the family.** Users and Access, Users, **+**, invite each person. The
   role must be one Apple accepts for internal testers: Account Holder, Admin,
   App Manager, Developer or Marketing. Choose the least privileged you are
   comfortable with, not Admin. Then on the group's page use **Invite
   Testers** (or **+** beside Testers) and tick each person. Each tester
   accepts the email invitation in the TestFlight app on their iPad. Internal
   testers can install builds for 90 days from upload.

### 2.5 App Store Connect API key into 1Password (§12.2 step 5)

One key, role **App Manager** (can manage builds and TestFlight; does not need
Admin). Only the Account Holder or an Admin can generate team keys, and the
Account Holder must first have requested API access once (Users and Access,
Integrations, **Request Access**)
([Apple: App Store Connect API](https://developer.apple.com/help/app-store-connect/get-started/app-store-connect-api/)).

1. Users and Access, **Integrations**, App Store Connect API, **Team Keys**,
   **Generate API Key**. Name `openmoji-testflight` (a label for you only).
   Access: **App Manager**. Generate. A key's name and access cannot be edited
   afterwards; to change either, revoke and regenerate.
2. Note the **Issuer ID** (shown at the top of the page) and the **Key ID**
   (in the key's row), and **Download** the `AuthKey_<KEY_ID>.p8`. Apple lets
   you download it **once**; if lost, revoke and generate a new key.
3. Store all three in 1Password as one item in the `OpenMoji` vault. The `.p8`
   goes in base64-encoded, which avoids newline and whitespace mangling as it
   round-trips through `op` and env-var injection (macOS `base64` does not wrap
   lines); the lane decodes it to a temporary `.p8` at run time.

   ```bash
   op item create --category="API Credential" \
     --title=testflight-asc-api-key --vault=OpenMoji \
     "issuer-id[text]=<Issuer ID>" \
     "key-id[text]=<Key ID>" \
     "private-key-base64[password]=$(base64 < ~/Downloads/AuthKey_<KEY_ID>.p8)"
   ```

   Assignment values land in shell history and the process list. If that
   bothers you, create the item in the 1Password app instead, with the same
   title, vault and three field labels.

4. Delete the downloaded file; 1Password is now the only copy:

   ```bash
   rm -f ~/Downloads/AuthKey_<KEY_ID>.p8
   ```

5. Verify the three references resolve (the last one prints only the PEM header
   line):

   ```bash
   op read op://OpenMoji/testflight-asc-api-key/issuer-id
   op read op://OpenMoji/testflight-asc-api-key/key-id
   op read op://OpenMoji/testflight-asc-api-key/private-key-base64 | base64 --decode | head -1
   # last line should be: -----BEGIN PRIVATE KEY-----
   ```

**This key is never added to GitHub** (section 1). If it is ever exposed
anywhere, revoke it immediately (Integrations, Team Keys, Revoke), then repeat
2.5 with a new key. Routine rotation is the same: generate the new key, update
`key-id` and `private-key-base64` (and `issuer-id` if it changed) in the
1Password item, then revoke the old key.

## 3. Expiry register

The distribution certificate and both profiles expire yearly, and a profile
expires no later than the certificate it embeds. When either expires, `make
testflight` fails at signing, so the dates are tracked here
([ADR-0011](../adr/0011-manual-per-target-signing.md)). **Update this table in
the same PR as any renewal.**

| Item | Expires (UTC) | Last renewed or created | Notes |
|---|---|---|---|
| Apple Distribution certificate, team `AB5S94XWRQ` | 2027-07-22 | _fill in at 2.3_ | Date read from the existing certificate on 2026-10-02; re-read at 2.3 (section 2.3, last command) to confirm it is the one in the signing keychain. If A7 fails and a second certificate is created, add a row |
| Profile `OpenMoji App Store` | _fill in at 2.2_ | _fill in at 2.2_ | Date from the loop in 2.2 |
| Profile `OpenMoji Messages App Store` | _fill in at 2.2_ | _fill in at 2.2_ | Date from the loop in 2.2 |

There is no automated alert for these yet (OQ-14, open). Until that is decided,
put a calendar reminder about 30 days before the earliest date. This is separate
from the TestFlight **build** expiry (90 days from upload), which the
`testflight-expiry` GitHub workflow and `make testflight-status` cover
([§12.6](../tech-spec.md#126-ci-and-expiry-automation-github-actions)).

Renewal, names unchanged so no repo edit is needed beyond this table:

- **Profile only** (certificate still valid): in the portal open the profile,
  Edit, regenerate it under the **same name**, download, install (2.2), re-read
  the expiry.
- **Certificate** (new Apple Distribution certificate): create it (2.0 step 4),
  regenerate **both** profiles against it (2.2), delete and recreate the signing
  keychain with the new identity (`security delete-keychain "$KC"`, then 2.3
  from step 2; the 1Password password item can be reused), and update the table.

## 4. Routine release

> Described as specified in [§12.3](../tech-spec.md#123-make-testflight-sequence-scriptsreleasesh-via-scriptsop-runsh)
> and [§12.6](../tech-spec.md#126-ci-and-expiry-automation-github-actions). The
> scripts are not written yet; this section adds no commands or flags beyond
> the spec.

On the release Mac, from a clean checkout of `main` that equals `origin/main`
with CI green on that commit:

```bash
make testflight           # archive, upload, distribute, tag
make testflight-status    # newest VALID build's exact expiry and processing state
```

Bump `MARKETING_VERSION` in `project.yml` by hand first if the user-visible
version should change; the build number is injected by the lane
(`git rev-list --count HEAD`, REL-3).

`make testflight` runs `scripts/release.sh` through `scripts/op-run.sh`, which
injects the 1Password secrets (approve in the 1Password app if it asks). In
order:

0. Puts `/usr/bin` first on `PATH`; stops on any error.
1. **Preflight:** clean tree, on `main`, `HEAD == origin/main`, CI green on
   `HEAD`, `xcode-select` points at Xcode.app, required env present.
2. **Secret scan** with gitleaks (REL-6).
3. **Generate** the project with `xcodegen generate`.
4. **Tests:** `swift test` for `OpenMojiCore` (REL-7).
5. **Keychain:** unlock `openmoji-signing.keychain-db` and put it first in the
   search list (restored on exit).
6. **Archive** `Release`, `generic/platform=iOS`, with the build number and
   `--keychain` flag; profiles come per target from `project.yml`. Then an
   artifact scan for `sk-` keys in the `.xcarchive`.
7. **Upload** with `xcodebuild -exportArchive` using
   `release/ExportOptions.plist` and the ASC key from 1Password (REL-1, REL-4).
8. **Post-upload** via `scripts/asc.swift`: wait for processing to reach
   VALID, set "What to Test" from `git log` since the previous `build-*` tag
   (REL-8), and make sure the build is in the `Family` group (REL-5).
9. **Tag** the commit `build-<N>` (annotated) and push it. That tag's date is
   what the CI expiry alert reads.

Steps 1 to 4 fail before anything is signed. Archives are kept at
`build/release/OpenMoji-<N>.xcarchive` (keep them for dSYMs). No export
compliance prompt is expected; the build declares HTTPS-only encryption
([§3](../tech-spec.md#3-targets-modules-and-entitlements)).

About two weeks before a build's 90 days are up, the scheduled workflow opens a
GitHub issue labelled `testflight-expiry`. Run `make testflight-status` to see
the exact date, then run `make testflight` again.

## 5. Pitfalls

These are known from the reference project and designed into the lane
([ADR-0010](../adr/0010-local-release-lane.md)); this is how to recognise and fix
them when running anything by hand.

### Homebrew rsync breaks `xcodebuild -exportArchive`

Symptom: export fails while packaging the IPA with an `rsync` usage error.
Cause: a Homebrew `rsync` 3.x earlier on `PATH` than Apple's `/usr/bin/rsync`.
Homebrew's does not understand macOS-specific options (on this Mac,
`/opt/homebrew/bin/rsync --extended-attributes` answers
`unknown option`, version 3.5.1).

```bash
which -a rsync                                   # /opt/homebrew/bin/rsync listed first = trouble
PATH="/usr/bin:$PATH" xcodebuild -exportArchive ...   # for a hand-run export
```

The lane does this itself (step 0).

### `errSecInternalComponent` during archive or `codesign`

Cause: codesign cannot use the private key without a prompt. Usually one of:

- The signing keychain is locked, or auto-lock was left on. Unlock it, and
  check the setting:

  ```bash
  security unlock-keychain -p "$(op read op://OpenMoji/openmoji-signing-keychain/password)" \
    "$HOME/Library/Keychains/openmoji-signing.keychain-db"
  security show-keychain-info "$HOME/Library/Keychains/openmoji-signing.keychain-db"
  ```

- The partition list is missing `apple:` and `codesign:`. Re-run 2.3 step 5's
  `set-key-partition-list`. The Keychain Access "Allow all applications to
  access this item" toggle does **not** change the partition list.
- The identity was left in the login keychain only. The login keychain locks
  and needs your macOS password, so it cannot serve an unattended run. Use the
  dedicated keychain.
- Two keychains in the search list both hold an "Apple Distribution" identity
  and codesign picks the wrong one. Always pass `--keychain <path>` (the lane
  does, via `OTHER_CODE_SIGN_FLAGS`).

### `xcode-select` points at Command Line Tools

Symptom: `xcode-select: error: tool 'xcodebuild' requires Xcode, but active
developer directory '/Library/Developer/CommandLineTools' is a command line
tools instance`. Fix:

```bash
xcode-select -p
sudo xcode-select -s /Applications/Xcode.app/Contents/Developer
```

The lane's preflight checks `xcode-select -p` and stops before signing.

### Profile problems

- Names must match exactly in the portal, `project.yml` and
  `release/ExportOptions.plist`. A profile that is not installed in
  `~/Library/Developer/Xcode/UserData/Provisioning Profiles/` cannot be found
  (re-run the 2.2 install and listing loop).
- A profile generated before App Groups was configured on its App ID lacks the
  group. Regenerate it, download, install.
- Never pass `PROVISIONING_PROFILE_SPECIFIER` on the `xcodebuild` command line.
  Command-line settings apply to every target and would sign the extension with
  the app's profile ([ADR-0011](../adr/0011-manual-per-target-signing.md)).

## 6. Provenance

Command syntax checked on 2026-10-02 against `man security`,
`op item create --help` and `xcodebuild -help`; the `security cms` and
`openssl x509` expiry commands were run against an installed profile and
certificate. ASC steps follow Apple's linked help pages. The reference project's
runbook was read for pitfalls only; nothing is copied.
