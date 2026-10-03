import SwiftUI

/// Switches on `AppModel.state`. Idle is real (Compose when expanded, "New
/// sticker" when compact); Generating, Preview and Error are placeholders for
/// separate beads. Settings is real: expanded with no key opens it directly
/// (FR-5), and Compose's gear opens it as a sheet.
struct RootView: View {
    let model: AppModel
    let settings: SettingsModel

    @State private var showingSettings = false

    var body: some View {
        content
            .sheet(isPresented: $showingSettings) {
                SettingsView(model: settings) { showingSettings = false }
            }
            // Clearing the key routes to needs-key, whose Settings replaces the sheet.
            .onChange(of: model.state == .needsKey) { _, needsKey in
                if needsKey { showingSettings = false }
            }
    }

    @ViewBuilder private var content: some View {
        switch model.state {
        case .needsKey:
            if model.presentationStyle == .expanded {
                // Done, once a key is saved, picks up the new key: needs-key → idle.
                SettingsView(model: settings) { model.refreshKey() }
            } else {
                Text("Set up OpenMoji")
            }
        case .idle:
            if model.presentationStyle == .expanded {
                ComposeView(model: model) { showingSettings = true }
            } else {
                CompactHomeView(model: model)
            }
        case .generating:
            Text("Making your sticker…")
        case .preview:
            Text("Preview")
        case .failed(let error, _):
            Text(error.userMessage ?? "Something went wrong.")
        }
    }
}
