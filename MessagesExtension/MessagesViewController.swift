import Messages
import OpenMojiCore
import SwiftUI

/// Hosts the one SwiftUI root and forwards host lifecycle into `AppModel`
/// (tech spec §10, ADR-0008).
final class MessagesViewController: MSMessagesAppViewController {
    private let model = AppModel(
        credentials: KeychainCredentialStore(),
        generator: GenerationService(credentials: KeychainCredentialStore(), client: OpenAIClient())
    )

    override func viewDidLoad() {
        super.viewDidLoad()
        model.presentationStyle = presentationStyle
        // Compact's "New sticker" needs the expanded style for text entry.
        model.requestExpandedStyle = { [weak self] in
            self?.requestPresentationStyle(.expanded)
        }

        // Clearing the key sends the model back to needs-key (FR-5).
        let settings = SettingsModel(
            credentials: KeychainCredentialStore(),
            validator: OpenAIClient(),
            onCleared: { [model] in model.refreshKey() }
        )
        #if DEBUG
            // Throwaway probe for openmoji-25h; remove before M4 features land.
            let probe = ProbeModel(
                requestStyle: { [weak self] in self?.requestPresentationStyle($0) },
                activeConversation: { [weak self] in self?.activeConversation }
            )
            let host = UIHostingController(rootView: ProbeEntry(probe: probe, model: model) {
                RootView(model: model, settings: settings)
            })
        #else
            let host = UIHostingController(rootView: RootView(model: model, settings: settings))
        #endif
        addChild(host)
        host.view.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(host.view)
        NSLayoutConstraint.activate([
            host.view.topAnchor.constraint(equalTo: view.topAnchor),
            host.view.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            host.view.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            host.view.trailingAnchor.constraint(equalTo: view.trailingAnchor),
        ])
        host.didMove(toParent: self)
    }

    override func willTransition(to presentationStyle: MSMessagesAppPresentationStyle) {
        super.willTransition(to: presentationStyle)
        model.presentationStyle = presentationStyle
    }

    override func didTransition(to presentationStyle: MSMessagesAppPresentationStyle) {
        super.didTransition(to: presentationStyle)
        model.presentationStyle = presentationStyle
    }

    /// Re-reads whether a key is stored, so no key routes to Set up in compact
    /// and Settings in expanded, and a key saved or cleared meanwhile is picked
    /// up (FR-5, tech spec §8). `AppModel` also does this once in `init`.
    override func willBecomeActive(with conversation: MSConversation) {
        super.willBecomeActive(with: conversation)
        model.refreshKey()
    }

    /// An in-flight generation is lost when Messages tears the extension down,
    /// so stop it here (tech spec §2 Lifecycle).
    override func willResignActive(with conversation: MSConversation) {
        super.willResignActive(with: conversation)
        model.cancel()
    }
}
