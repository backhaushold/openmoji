import SwiftUI

/// Switches on `AppModel.route`. Idle is real (Compose when expanded, "New
/// sticker" when compact); Generating, Preview and Error are placeholders for
/// separate beads. Settings is real: expanded with no key opens it directly
/// (FR-5), compact with no key offers "Set up OpenMoji", and Compose's gear
/// opens it as a sheet.
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
        switch model.route {
        case .compactHome:
            CompactHomeView(model: model, needsSetUp: false)
        case .compactSetUp:
            CompactHomeView(model: model, needsSetUp: true)
        case .settings:
            // Done, once a key is saved, picks up the new key: needs-key → idle.
            SettingsView(model: settings) { model.refreshKey() }
        case .compose:
            ComposeView(model: model) { showingSettings = true }
        case .generating:
            Text("Making your sticker…")
        case .preview:
            Text("Preview")
        case .failed(let error):
            Text(error.userMessage ?? "Something went wrong.")
        }
    }
}
