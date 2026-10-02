# ADR-0006: App Group container and shared Keychain access group

- **Status:** Accepted (user, 2026-10-02: "do 1 if the delta is small")
- **Date:** 2026-10-02

## Context
In v1 only the Messages extension reads the library and the API key; the shell app has no UI for either. Without sharing, the extension would use its own sandbox container and default Keychain group. The deferred media-context extension (OQ-1), or any future shell-app feature, would then be unable to reach existing stickers or the key without a migration.

## Decision
- Both targets get the entitlement `com.apple.security.application-groups = [group.com.backhaushold.openmoji]`. The library lives in that container.
- Both targets get `keychain-access-groups = [$(AppIdentifierPrefix)com.backhaushold.openmoji.shared]`. The key item sets `kSecAttrAccessGroup` to it explicitly.

## Delta versus not sharing (why it's small)
- Two short `.entitlements` files.
- Tick App Groups on both App IDs when registering them, which M3 does anyway, before generating profiles.
- `containerURL(forSecurityApplicationGroupIdentifier:)` instead of `FileManager.urls(for: .applicationSupportDirectory…)`.
- One extra attribute in Keychain queries.
- No ongoing cost.

## Alternatives
- **Extension-private container and default Keychain group.** Marginally simpler today. Adding a second process later would need a data migration from the extension's sandbox, which can only be done from inside the extension.

## Consequences
- Profiles must be regenerated if the group ID ever changes.
- The App Group must be a valid `group.` identifier; `containerURL` returns nil on iOS for an invalid one, so `LibraryStore` fails loudly at startup.
