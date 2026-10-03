import SwiftUI

/// Switches on `AppModel.state`. Placeholder content only: Compose, Generating,
/// Preview, Error and Settings are separate beads.
struct RootView: View {
    let model: AppModel

    var body: some View {
        switch model.state {
        case .needsKey:
            Text("Set up OpenMoji")
        case .idle:
            Text("OpenMoji")
        case .generating:
            Text("Making your sticker…")
        case .preview:
            Text("Preview")
        case .failed(let error, _):
            Text(error.userMessage ?? "Something went wrong.")
        }
    }
}
