# ADR-0007: Keychain item attributes for the OpenAI key

- **Status:** Proposed
- **Date:** 2026-10-02

## Context
FR-2: the key is stored in the Keychain, device-only, never iCloud-synced. The key is used only while the user is in Messages with the extension on screen, so the device is necessarily unlocked. There is no background use.

## Decision
- A generic password item: service `com.backhaushold.openmoji.openai`, account `api-key`, access group per ADR-0006.
- `kSecAttrAccessible = kSecAttrAccessibleWhenUnlockedThisDeviceOnly`.
- `kSecAttrSynchronizable = false`.
- Save is add-or-update; clear treats `errSecItemNotFound` as success.

## Alternatives
- **`AfterFirstUnlockThisDeviceOnly`.** Apple recommends it for background access, which we don't need. It leaves the key readable while the device is locked after the first unlock.
- **`WhenPasscodeSetThisDeviceOnly`.** Stricter, but the item is deleted if the passcode is removed and saving fails on a device without a passcode, a poor fit for family iPads.
- **Access control with `.userPresence`.** Face ID or Touch ID on every generation is friction the PRD doesn't ask for; the spend risk is covered by the OpenAI budget cap (D7).

## Consequences
- The key never leaves the device and isn't in backups restored to another device. A new or restored iPad requires re-entry, which the PRD's model expects.
