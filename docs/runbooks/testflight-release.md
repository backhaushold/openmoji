# Runbook: TestFlight release (OpenMoji)

One-time Apple and Mac setup for the release lane, the expiry register, and a
short routine-release section. Design lives in the
[tech spec §12](../tech-spec.md#12-release-pipeline) and
[ADR-0010](../adr/0010-local-release-lane.md),
[ADR-0011](../adr/0011-manual-per-target-signing.md),
[ADR-0015](../adr/0015-app-store-connect-api-tooling.md) and
[ADR-0016](../adr/0016-onepassword-service-account-auth.md) (1Password service
account); this file is the "how", the spec is the "why".

> **Status.** The one-time setup (section 2) is actionable now. The whole lane
> (`make testflight`, `scripts/op-run.sh`, `scripts/release.sh`,
> `release/ExportOptions.plist`, `release/.env.example`; §12.3 steps 0 to 9) is
> built (beads `openmoji-4kq` and `openmoji-2pq`), as are `scripts/asc.swift` and
> `make testflight-status`. Steps 8 and 9 and `asc.swift` have only been run
> against a local stub server so far: the first real upload (bead `openmoji-i5k`)
> is their first contact with App Store Connect, so read their output then.

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
- The optional 1Password service-account token (section 2.6) lives only in the
  git-ignored `.env` on the release Mac, mode 600. It is never committed, never
  added to GitHub, and never read into an issue, PR, bead, chat or AI agent
  session.
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

   This is the interactive mode (1Password app approval). For unattended runs,
   section 2.6 sets up a read-only service account instead.

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
`~/Library/MobileDevice/Provisioning Profiles/`). `open` can return without
installing anything (seen 2026-10-03); if the loop below doesn't list them,
copy each file in under its UUID, which is what Xcode does:

```bash
D="$HOME/Library/Developer/Xcode/UserData/Provisioning Profiles"
for f in ~/Downloads/OpenMoji_App_Store.mobileprovision ~/Downloads/OpenMoji_Messages_App_Store.mobileprovision; do
  cp -f "$f" "$D/$(security cms -D -i "$f" | plutil -extract UUID raw -o - -).mobileprovision"
done
```

Confirm both are installed and read their expiry dates:

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
   `release/.env.example` references the same path.

2. **Create the keychain** with that password. `security` warns that `-p` is
   "insecure" because the value is visible in the process list for an instant;
   acceptable for a one-time step on a single-user Mac. Omit `-p ...` to be
   prompted instead.

   Read the password into a variable and check it is non-empty first. If the
   1Password approval prompt times out, `op read` prints nothing and
   `create-keychain -p ""` happily makes a keychain with an **empty** password
   (happened 2026-10-03). Every `-p`/`-k` below uses the same guard.

   ```bash
   PW="$(op read "$KC_PW_REF")" && [ -n "$PW" ] && security create-keychain -p "$PW" "$KC"
   ```

3. **Turn off auto-lock.** Passing neither `-t <seconds>` (timeout) nor `-l`
   (lock on sleep) means "no timeout, never lock on sleep":

   ```bash
   security set-keychain-settings "$KC"
   security unlock-keychain -p "$PW" "$KC"
   security show-keychain-info "$KC"      # should report no-timeout
   ```

   If you suspect an empty password, `security lock-keychain "$KC" &&
   security unlock-keychain -p "" "$KC"` must **fail**; if it succeeds,
   `security delete-keychain "$KC"` and start again from step 2.

4. **Export the Apple Distribution identity as a `.p12`.** Use Keychain Access
   rather than `security export`: Keychain Access, the keychain that holds the
   certificate, My Certificates, "Apple Distribution: ...", right-click,
   **Export...**, format **Personal Information Exchange (.p12)**, save as
   `~/openmoji-dist.p12`, choose a throwaway export password. (`security export
   -t identities` exports **every** identity in a keychain, not just this one.)

   Alternative (used 2026-10-03): copy the identity (certificate and its
   private key) into the signing keychain directly in Keychain Access, then
   skip the `security import` line in step 5 and step 6, but **still run
   `set-key-partition-list`**: a key copied in the UI is not usable by
   `codesign` unattended until it is set.

5. **Import it with `codesign` authorised**, then **set the partition list**.
   Both are needed: `-T` adds `/usr/bin/codesign` to the key's access list and
   the partition list is what actually lets codesign use the key without a
   prompt. Omitting `-P` makes `security import` ask for the `.p12` password in
   a dialog, which keeps it out of shell history.

   ```bash
   security import ~/openmoji-dist.p12 -k "$KC" -T /usr/bin/codesign
   security set-key-partition-list -S apple-tool:,apple:,codesign: -s \
     -k "$PW" "$KC" >/dev/null
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
   security unlock-keychain -p "$PW" "$KC"
   T=$(mktemp -d) && cp -f /bin/ls "$T/ls-test"
   codesign -f -s "Apple Distribution" --keychain "$KC" "$T/ls-test"
   rm -rf "$T"
   unset PW
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
2. Note the **Issuer ID** (a UUID, shown at the top of the page above the keys
   table) and the **Key ID** (10 characters, in the key's row and in the file
   name); they are easy to swap. **Download** the `AuthKey_<KEY_ID>.p8`. Apple lets
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

### 2.6 Non-interactive 1Password auth: a service account (optional)

Design: [ADR-0016](../adr/0016-onepassword-service-account-auth.md).
`scripts/op-run.sh` authenticates `op` one of two ways, chosen by whether a
`.env` exists at the repo root:

| | Service account | Interactive |
|---|---|---|
| When | `.env` holds `OP_SERVICE_ACCOUNT_TOKEN=<token>` | no `.env` (the default) |
| Prompt | none; `make testflight` can run unattended | the 1Password app may ask for approval |
| Needs | the token; the file must be mode 600 | 1Password app unlocked, Settings, Developer, **Integrate with the 1Password CLI** on |
| `op-run.sh` prints | `1Password auth: service account (token from .env)` | `1Password auth: interactive` |

Either way the script first runs `op vault get OpenMoji` (vault metadata, no
item is read) and stops with `1Password authentication failed ... Nothing was
run.` if that fails, before `release.sh` starts. `make op-check` runs only that
check.

To switch to the service account (skip this section to stay interactive):

1. **Create the service account, read-only on the `OpenMoji` vault.** You need
   to be signed in to `op` as someone allowed to create service accounts; if
   your plan or role does not allow it, stay interactive. Only `read_items` is
   needed: the lane reads the signing-keychain password and the ASC key and
   writes nothing. A service account's vault access cannot be edited after
   creation; to change it, create a new one. Run from the repo root. The token
   is returned **once**, so this writes it straight into a new `.env` (created
   `0600`, never shown, never in a variable or in your shell history; `set -C`
   makes it refuse to overwrite an existing `.env`, in which case no service
   account is created):

   ```bash
   ( set -C; umask 077; { printf 'OP_SERVICE_ACCOUNT_TOKEN='; \
       op service-account create openmoji-release --vault OpenMoji:read_items --raw; } > .env )
   ```

   Optional: add `--expires-in 52w` (seconds, minutes, hours, days or weeks) so
   the token lapses by itself; then add a row for it to the expiry register
   (section 3) and renew it the same way. You can also create the account in
   your 1Password account's web settings (Developer, service accounts), grant
   the `OpenMoji` vault **Read** only, and paste the token into `.env` with an
   editor after `cp .env.example .env && chmod 600 .env`. The format is one line,
   `OP_SERVICE_ACCOUNT_TOKEN=<token>`, no spaces, no trailing comment.

2. **Check the file mode.** Group or other access makes `op-run.sh` refuse the
   file:

   ```bash
   chmod 600 .env
   ls -l .env     # -rw-------
   ```

3. **Check it works** without any prompt:

   ```bash
   make op-check
   # want: op-run: ok, authenticated (service account (token from .env)) and the OpenMoji vault is readable
   ```

`.env` is git-ignored, and only `.env.example` (an empty placeholder) is
committed. **Never commit `.env`, paste the token anywhere, or open the file in
an AI agent session**; treat it like the signing-keychain password. The token
reaches only `op` (through the environment; it is never in a command line or
printed, and `op-run.sh` runs `release.sh` without it). If it is exposed, or
the Mac is lost, delete the service account in your 1Password account's web
settings (the CLI cannot revoke it), `rm -f .env`, and repeat the steps above.
The same is the rotation procedure. To return to interactive auth, `rm -f .env`
(and `unset OP_SERVICE_ACCOUNT_TOKEN` if your shell exports it).

`1Password authentication failed` with a token in `.env` means the token was
revoked or expired, or its service account cannot read the `OpenMoji` vault.
`.env ... readable by other users` is the mode check (step 2). `OP_SERVICE_ACCOUNT_TOKEN
is empty` is the unedited `.env.example` placeholder.

## 3. Expiry register

The distribution certificate and both profiles expire yearly, and a profile
expires no later than the certificate it embeds. When either expires, `make
testflight` fails at signing, so the dates are tracked here
([ADR-0011](../adr/0011-manual-per-target-signing.md)). **Update this table in
the same PR as any renewal.**

| Item | Expires (UTC) | Last renewed or created | Notes |
|---|---|---|---|
| Apple Distribution certificate, team `AB5S94XWRQ` | 2027-07-22 01:19:37 | Pre-existing; copied into the signing keychain 2026-10-03 | A7 confirmed 2026-10-03: the team's existing certificate (SHA-1 `541C8977…B15E`) signs OpenMoji; date re-read from the signing keychain. If a second certificate is ever created, add a row |
| Profile `OpenMoji App Store` | 2027-07-22 01:19:37 | 2026-10-03 | Capped at the certificate's expiry |
| Profile `OpenMoji Messages App Store` | 2027-07-22 01:19:37 | 2026-10-03 | Capped at the certificate's expiry |

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

> As built for [§12.3](../tech-spec.md#123-make-testflight-sequence-scriptsreleasesh-via-scriptsop-runsh)
> steps 0 to 9 and `make testflight-status`
> ([§12.6](../tech-spec.md#126-ci-and-expiry-automation-github-actions)).

On the release Mac, from a clean checkout of `main` that equals `origin/main`
with CI green on that commit:

```bash
make testflight           # preflight, tests, archive, upload, wait for VALID, What to Test, Family group, build-N tag
make testflight-status    # the newest build's processing state and exact expirationDate (read-only)
```

Bump `MARKETING_VERSION` in `project.yml` by hand first if the user-visible
version should change; the build number is injected by the lane
(`git rev-list --count HEAD`, REL-3).

`make testflight` runs `scripts/release.sh` through `scripts/op-run.sh`. That
first authenticates `op` (the service-account token in `.env` if there is one,
else the 1Password app; section 2.6) and checks it can read the `OpenMoji`
vault, stopping with a message before anything else runs if not. Then it runs
`op run --env-file release/.env.example` so 1Password injects four variables
for that one process (in interactive mode, approve in the 1Password app if it
asks; `release.sh` is started without the service-account token):
`SIGNING_KEYCHAIN_PASSWORD` (`op://OpenMoji/openmoji-signing-keychain/password`,
2.3) and `ASC_ISSUER_ID`, `ASC_KEY_ID`, `ASC_PRIVATE_KEY_BASE64` (from
`op://OpenMoji/testflight-asc-api-key/`, 2.5). The signing keychain path is not
secret and defaults to `~/Library/Keychains/openmoji-signing.keychain-db`; set
`SIGNING_KEYCHAIN_PATH` to override it (no whitespace). In order:

0. Puts `/usr/bin` first on `PATH`; stops on any error; a trap cleans up on
   every exit path.
1. **Preflight.** The first check that fails stops the lane with a message
   saying what to fix, before anything is signed:
   - the tools exist (`gh`, `gitleaks`, `xcodegen`, plus Xcode's own), the four
     variables are set and resolved, `release/ExportOptions.plist` and the signing
     keychain file exist, and `xcode-select -p` points at an `Xcode*.app`;
   - the tree is clean, the branch is `main`, and `HEAD` equals `origin/main`
     after a `git fetch origin main` (so the commit count is monotonic);
   - CI is green on `HEAD`: `gh api` lists the check runs for that commit; the
     `verify` check run must exist and every check run must be completed and not
     failed. Right after merging, wait for the push-to-`main` CI run to finish
     ("CI is still running").
2. **Secret scan:** `gitleaks detect --redact --no-banner` (REL-6). It scans the
   history of **every ref this clone has**, remote-tracking branches included,
   not just `main`, so a leaked or probe commit on any branch fails the lane.
3. **Generate** the project with `xcodegen generate`.
4. **Tests:** `swift test` for `OpenMojiCore` (REL-7).
5. **Keychain:** unlock `openmoji-signing.keychain-db`, check that it holds an
   `Apple Distribution` identity, and put it first in the user keychain search
   list. The original list is restored on exit.
6. **Archive:** `xcodebuild archive -project OpenMoji.xcodeproj -scheme OpenMoji
   -configuration Release -destination generic/platform=iOS -archivePath
   build/release/OpenMoji-<N>.xcarchive CURRENT_PROJECT_VERSION=<N>
   OTHER_CODE_SIGN_FLAGS="--keychain <signing keychain>"`, where `<N>` is
   `git rev-list --count HEAD`. Nothing else is on the command line; profiles
   come per target from `project.yml`. **6b:** then `grep -rlaE
   'sk-[A-Za-z0-9_-]{20,}'` over the whole `.xcarchive`, binaries included. Any
   hit fails the lane before upload; the message lists file names, never the
   match.
7. **Upload:** decode the ASC key into a `0600` `AuthKey_<KEY_ID>.p8` in a
   private temporary directory, run `xcodebuild -exportArchive` with
   `release/ExportOptions.plist`, `-exportPath build/release/export-<N>` (the
   packaging logs) and `-authenticationKeyPath/-ID/-IssuerID` (REL-1, REL-4),
   and delete the temporary directory straight afterwards. It is also deleted
   on failure, Ctrl-C, `SIGTERM` and `SIGHUP`.
8. **Post-upload** via `swift scripts/asc.swift`, which reads the same three
   `ASC_*` variables (the key is decoded in memory, never written):
   - `wait-for-build <N>` polls App Store Connect every 30 s (override with
     `ASC_POLL_INTERVAL`) for up to 45 min (`ASC_WAIT_TIMEOUT`, seconds) until
     the build's `processingState` is `VALID`. A build that is not listed yet
     counts as still processing. `INVALID` or `FAILED` fails the lane.
   - `set-whats-new <N> <text>` sets "What to Test" (REL-8) to
     `git log build-<prev>..HEAD --format='- %s'`, where `build-<prev>` is the
     highest earlier `build-<number>` reachable from `HEAD`. **The first upload
     has no earlier tag:** the text is `First TestFlight build. Most recent
     changes:` and the 20 newest commit subjects.
   - `ensure-in-group <N> Family` (REL-5) adds the build to the internal
     `Family` group unless it is already there, and says which it was ("already
     in group Family" means automatic distribution did it; "added build ..."
     means it did not, which is the answer to OQ-13, `openmoji-ppj`).
9. **Tag** the commit `build-<N>` (annotated, message `TestFlight upload <UTC
   time>`) and push just that tag. It runs **only after step 8 succeeded**, so a
   `build-<N>` tag always means a VALID build in `Family`. Its date is what the
   CI expiry alert reads.

Nothing is signed before step 6; steps 1 to 4 fail before the keychain is even
touched, and a failure prints which step it was in and whether anything was
signed. Archives are kept at `build/release/OpenMoji-<N>.xcarchive` (keep them
for dSYMs); a re-run on the same commit replaces that archive. If an earlier
run's upload was accepted by Apple, a re-run on the same commit reuses its build
number and App Store Connect rejects it as a duplicate; land a new commit
first. No export compliance prompt is expected; the build declares
HTTPS-only encryption ([§3](../tech-spec.md#3-targets-modules-and-entitlements)).

`make release-test` (`scripts/test-release.sh`, then `scripts/test-asc.sh`)
exercises the lane scripts with every external tool stubbed: each preflight
failure, the `sk-` scan, cleanup of the temporary key and the keychain search
list on success, failure and signals, and steps 8 and 9 (the order of the
`asc.swift` calls, the What to Test text, and that the `build-<N>` tag is
annotated and pushed only after the build is VALID, never on INVALID, a
timeout or a failed step). It also covers `op-run.sh`'s two auth modes with a
stub `op` and a fake token in a fixture directory (never your real `.env`), and
`make testflight-status`. `test-asc.sh` runs `asc.swift` itself against a local
stub HTTP server on 127.0.0.1 with a throwaway key (JWT header, claims and
signature, polling, error handling, the What to Test and group requests). None of
it signs, uploads or calls App Store Connect; run it after editing the scripts.

### Reading `make testflight-status`

```text
asc: newest build 12: state=VALID uploaded=2026-10-03T10:00:00-07:00 expirationDate=2027-01-01T10:00:00.123-08:00 (2027-01-01T18:00:00Z, 90 days left)
```

`expirationDate` is Apple's own string; the parenthesis is the same instant in
UTC and the days left (`EXPIRED` once it has passed). If the newest build is
still `PROCESSING` (or `FAILED`/`INVALID`), a second line shows the newest
`VALID` build and its expiry. Exit code 1 with "no builds are listed" means
nothing has been uploaded yet; `HTTP 401` or `403` means the key is wrong,
revoked or lacks App Manager (2.5).

About two weeks before a build's 90 days are up, the scheduled workflow opens a
GitHub issue labelled `testflight-expiry`. Run `make testflight-status` to see
the exact date, then run `make testflight` again.

### If the lane fails after the upload

Once step 7 succeeds the build is at Apple, so a re-run of `make testflight` on
the same commit is rejected as a duplicate build number. The lane's failure line
then says `Build <N> WAS uploaded` and no `build-<N>` tag has been pushed (the tag
is pushed last). Find the case, finish by hand, then push the tag so the expiry
alert sees the build. Run the `asc.swift` commands through `op-run.sh` so the key
is injected; `<N>` is the build number from the failure line.

- **`did not become VALID`, exit 3 (timeout).** Processing may still finish. Run
  `make testflight-status` until the build is `VALID`, then continue below.
- **`finished processing as INVALID` or `FAILED` (exit 4).** Apple emails the
  account holder the reasons (and App Store Connect, TestFlight shows them).
  Fix the cause, land a new commit, run `make testflight` again. Do not tag.
- **`VALID but its What to Test text could not be set`.** Read asc's error above
  it, then repeat that step by hand, or set the text in App Store Connect:

  ```bash
  scripts/op-run.sh swift scripts/asc.swift set-whats-new <N> "$(git log build-<prev>..HEAD --format='- %s')"
  ```

- **`could not be put in the Family group`.**
  `scripts/op-run.sh swift scripts/asc.swift ensure-in-group <N> Family`, or add
  the build to the group in App Store Connect. The error names the cause (no
  such group, group not internal, build not VALID).
- **`pushing the tag failed`.** The annotated tag exists locally. Run the command
  the lane printed: `git push origin refs/tags/build-<N>`.
- **Everything else is done** and only the tag is missing (for example after the
  fixes above): from the released commit, `git tag -a build-<N> -m "TestFlight
  upload $(date -u +%FT%TZ)" <commit>` and `git push origin refs/tags/build-<N>`.
  Tag the commit that was released, which is the one whose commit count is `<N>`
  (`git rev-list --count <commit>`).

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
`op item create --help` and `xcodebuild -help`; the 1Password service-account
steps (2.6) against `op service-account create --help` (`--vault
<name>:read_items`, `--raw`, `--expires-in`, token shown once, no revoke
subcommand) and `op vault get --help` on 1Password CLI 2.39.0, 2026-10-02; the `security cms` and
`openssl x509` expiry commands were run against an installed profile and
certificate. The lane's own commands (section 4) were checked the same day
against `xcodebuild -help` (archive and export flags, export option keys),
`man security` (`unlock-keychain`, `list-keychains`), `op run --help`,
`gitleaks detect --help` and `gh api --help`, and its `gh api` check-run query
was run read-only against `origin/main`. ASC steps follow Apple's linked help pages. The reference project's
runbook was read for pitfalls only; nothing is copied.

The App Store Connect API calls in `scripts/asc.swift` (section 4, steps 8 and
9, and `make testflight-status`) were checked on 2026-10-03 against Apple's
documentation (`developer.apple.com/documentation/appstoreconnectapi`, read as
the documentation site's JSON): the JWT header (`alg` ES256, `kid`, `typ`) and
claims (`iss`, `iat`, `exp`, `aud` `appstoreconnect-v1`) and the 20-minute limit
on a token's life; `GET /v1/builds` filters, sort values and the build
attributes `processingState` (`PROCESSING`, `FAILED`, `INVALID`, `VALID`) and
`expirationDate`; `GET /v1/apps` and `GET /v1/betaGroups` filters and the
`isInternalGroup` and `hasAccessToAllBuilds` attributes; the
`betaBuildLocalizations` create and update bodies (`whatsNew`); and
`POST /v1/builds/{id}/relationships/betaGroups` (204). No request has been made
to the real API yet (no key exists until `openmoji-t2m`). The documentation does
not state the `whatsNew` length limit. `asc.swift` cuts the text at 4000
characters, a figure from memory of the TestFlight web UI that has **not** been
confirmed against Apple's documentation; if App Store Connect rejects a text, the
409 detail in the lane's failure output says so, and the cap in `asc.swift`
(`Config.maxWhatsNewLength`) is the one number to change.
