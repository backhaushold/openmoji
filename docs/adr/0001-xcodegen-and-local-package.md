# ADR-0001: XcodeGen project and a local Swift package for shared logic

- **Status:** Proposed
- **Date:** 2026-10-02

## Context
OpenMoji has two targets (shell app, Messages extension). Hand-edited `.xcodeproj` files conflict badly in PRs. Sagelet already uses XcodeGen successfully. REL-7 needs processing and error-mapping tests to run before every upload, and Sagelet's experience shows the local simulator is unreliable on the owner's Mac (Xcode beta / CoreSimulator mismatch).

## Decision
- Define the project in XcodeGen `project.yml`; git-ignore the generated `.xcodeproj`.
- Put all non-UI logic (client, processor, store, credential, error mapping, config, template) in a local Swift package `Packages/OpenMojiCore`, depending only on Apple frameworks available on both iOS and macOS.
- Run its tests with `swift test` on the Mac host, in CI and in the release lane.

## Alternatives
- **Checked-in `.xcodeproj`.** No tooling dependency, but merge conflicts and opaque diffs.
- **Tuist.** More powerful, but heavier and not used elsewhere in backhaushold.
- **Logic inside the extension target.** Tests would need a simulator and a host app.

## Consequences
- `brew install xcodegen` is required locally and in CI.
- Core code must avoid UIKit (use ImageIO, CoreGraphics and UniformTypeIdentifiers), which suits NFR-5 anyway.
- The package declares `platforms: [.iOS(.v26), .macOS(.v15)]`. The macOS floor must not exceed the Mac and CI runner OS.
