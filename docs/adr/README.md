# Architecture Decision Records

One file per significant technical decision in the [tech spec](../tech-spec.md). Format: Status, Context, Decision, Alternatives, Consequences. Status is one of Proposed, Accepted, Superseded.

| ADR | Decision | Status |
|---|---|---|
| [0001](0001-xcodegen-and-local-package.md) | XcodeGen project + local Swift package for shared logic | Proposed |
| [0002](0002-images-generations-endpoint.md) | Images API `/v1/images/generations`, not the Responses API tool | Proposed |
| [0003](0003-urlsession-client.md) | Plain `URLSession` async client, no SDK | Proposed |
| [0004](0004-imageio-thumbnail-pipeline.md) | ImageIO thumbnail-from-encoded + PNG step-down ladder | Proposed |
| [0005](0005-library-storage-format.md) | Library as PNG files + atomic JSON index | Proposed |
| [0006](0006-app-group-and-keychain-group.md) | App Group + shared Keychain access group | Accepted |
| [0007](0007-keychain-item-attributes.md) | Keychain item: generic password, WhenUnlockedThisDeviceOnly, non-synchronizable | Proposed |
| [0008](0008-swiftui-with-msstickerview.md) | SwiftUI in `MSMessagesAppViewController`, `MSStickerView` cells | Proposed |
| [0009](0009-key-validation.md) | Validate keys with `GET /v1/models/{id}` | Accepted |
| [0010](0010-local-release-lane.md) | Local `make testflight` lane, reimplemented from the Sagelet pattern | Accepted |
| [0011](0011-manual-per-target-signing.md) | Manual signing with per-target profiles in `project.yml` | Proposed |
| [0012](0012-secret-scanning-gitleaks.md) | gitleaks in CI and the release lane | Proposed |
| [0013](0013-generation-config-build-settings.md) | Model ID and quality via build settings → Info.plist | Proposed |
| [0014](0014-ipad-only-device-family.md) | iPad-only device family | Accepted |
| [0015](0015-app-store-connect-api-tooling.md) | App Store Connect API via a dependency-free Swift script | Proposed |

"Accepted" means the user chose the option on 2026-10-02. "Proposed" means it is recommended in the spec and awaiting review with the spec PR.
