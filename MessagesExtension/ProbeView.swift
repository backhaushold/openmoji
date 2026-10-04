// Throwaway probe for openmoji-25h; remove before M4 features land.
//
// Debug builds only. It answers on a real iPad Air: OQ-10 (do MSStickerView's
// tap and peel-and-drag coexist with a SwiftUI long-press context menu?), OQ-11
// and A5 (does MSSticker accept a file URL in the App Group container?), A3
// (does a TextField work in expanded?) and A4 (tap and peel in both styles).
//
// To remove it: delete this file, ProbeSticker.png and the `#if DEBUG` block in
// MessagesViewController.viewDidLoad, then run `xcodegen generate`.
#if DEBUG
    import Messages
    import Observation
    import OpenMojiCore
    import SwiftUI

    /// Builds the probe stickers and keeps an on-screen log, so every result can be
    /// read off the device without a debugger.
    @MainActor
    @Observable
    final class ProbeModel {
        /// A sticker, or the text of the error that stopped it being made.
        enum Outcome {
            case sticker(MSSticker)
            case failed(String)
        }

        private(set) var steps: [String] = []
        private(set) var appGroup: Outcome = .failed("not prepared yet")
        private(set) var bundle: Outcome = .failed("not prepared yet")
        private(set) var events: [String] = []

        @ObservationIgnored private let requestStyle: @MainActor (MSMessagesAppPresentationStyle) -> Void
        @ObservationIgnored private let activeConversation: @MainActor () -> MSConversation?

        init(
            requestStyle: @escaping @MainActor (MSMessagesAppPresentationStyle) -> Void,
            activeConversation: @escaping @MainActor () -> MSConversation?
        ) {
            self.requestStyle = requestStyle
            self.activeConversation = activeConversation
        }

        func request(_ style: MSMessagesAppPresentationStyle) {
            requestStyle(style)
        }

        func note(_ text: String) {
            events.append("\(Date.now.formatted(date: .omitted, time: .standard))  \(text)")
        }

        func clearEvents() {
            events = []
        }

        /// Copies the bundled PNG into the App Group container and makes a sticker
        /// from that file URL (OQ-11, A5). Also makes one from the bundle URL, as a
        /// control: if the App Group sticker fails but this one works, the App
        /// Group URL is the cause and not the PNG.
        func prepare() {
            steps = []
            appGroup = .failed("not prepared yet")
            bundle = .failed("not prepared yet")

            guard let bundled = Bundle.main.url(forResource: "ProbeSticker", withExtension: "png") else {
                steps.append("Bundled ProbeSticker.png: MISSING from the extension bundle")
                return
            }
            steps.append("Bundled ProbeSticker.png: found, \(Self.size(of: bundled))")
            bundle = Self.makeSticker(from: bundled, label: "bundle URL (control)", steps: &steps)

            let identifier = LibraryStore.appGroupIdentifier
            guard let container = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: identifier) else {
                steps.append("App Group container for \(identifier): nil (entitlement or profile problem)")
                appGroup = .failed("No App Group container")
                return
            }
            steps.append("App Group container: \(container.path)")

            let directory = container.appending(path: "Probe", directoryHint: .isDirectory)
            let copy = directory.appending(path: "ProbeSticker.png")
            do {
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                try? FileManager.default.removeItem(at: copy)
                try FileManager.default.copyItem(at: bundled, to: copy)
            } catch {
                steps.append("Copy into the App Group container: FAILED, \(Self.describe(error))")
                appGroup = .failed("Copy failed")
                return
            }
            let readable = FileManager.default.isReadableFile(atPath: copy.path)
            steps.append("Copied to \(copy.path): \(Self.size(of: copy)), readable by FileManager: \(readable ? "yes" : "NO")")
            appGroup = Self.makeSticker(from: copy, label: "App Group URL", steps: &steps)
        }

        /// The A4 fallback from ADR-0008: insert through the conversation instead
        /// of relying on a tap on `MSStickerView`.
        func insertViaConversation() {
            guard case .sticker(let sticker) = appGroup else {
                note("activeConversation.insert: no App Group sticker to insert")
                return
            }
            guard let conversation = activeConversation() else {
                note("activeConversation.insert: no active conversation")
                return
            }
            conversation.insert(sticker) { @Sendable [weak self] error in
                let result = error.map { Self.describe($0) } ?? "ok"
                Task { @MainActor in self?.note("activeConversation.insert: \(result)") }
            }
        }

        private static func makeSticker(from url: URL, label: String, steps: inout [String]) -> Outcome {
            do {
                let sticker = try MSSticker(contentsOfFileURL: url, localizedDescription: "OpenMoji probe sticker")
                steps.append("MSSticker from \(label): created")
                return .sticker(sticker)
            } catch {
                let text = describe(error)
                steps.append("MSSticker from \(label): THREW, \(text)")
                return .failed(text)
            }
        }

        private nonisolated static func describe(_ error: any Error) -> String {
            let nsError = error as NSError
            return "\(nsError.domain) code \(nsError.code): \(nsError.localizedDescription)"
        }

        private static func size(of url: URL) -> String {
            let bytes = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int) ?? nil
            return bytes.map { "\($0) bytes" } ?? "size unknown"
        }
    }

    /// Wraps the real root view and adds one clearly labelled "Probe" bar at the
    /// bottom that swaps in `ProbeView`. Nothing else about the normal flow changes.
    struct ProbeEntry<Content: View>: View {
        let probe: ProbeModel
        let model: AppModel
        let content: Content

        @State private var showingProbe = false

        init(probe: ProbeModel, model: AppModel, @ViewBuilder content: () -> Content) {
            self.probe = probe
            self.model = model
            self.content = content()
        }

        var body: some View {
            if showingProbe {
                ProbeView(probe: probe, style: model.presentationStyle) { showingProbe = false }
            } else {
                content.safeAreaInset(edge: .bottom) {
                    Button("Open device probe (debug, openmoji-25h)") { showingProbe = true }
                        .font(.caption)
                        .buttonStyle(.bordered)
                        .tint(.red)
                        .padding(.bottom, 4)
                }
            }
        }
    }

    struct ProbeView: View {
        let probe: ProbeModel
        let style: MSMessagesAppPresentationStyle
        let onClose: () -> Void

        @State private var typed = ""

        private var expanded: Bool { style == .expanded }

        private static let checklist = [
            "Read \"What happened\" below. Any THREW, MISSING or nil line is the OQ-11 answer: note the exact text.",
            "Compact: tap A, B and C once each. Does the sticker land in Messages' message field? (A4)",
            "Compact: touch and hold A, B and C, then drag into the thread. Does it peel off and drop? (A4)",
            "Compact: touch and hold A without moving. Does the context menu appear? Does peel still start? Which wins? Compare with B, which has no menu. (OQ-10)",
            "Choose a menu item on A and check the log says it fired. Check the app did not also peel or insert.",
            "Tap \"Insert A via activeConversation.insert\": does it land in the message field, and what does the log say? (A4 fallback)",
            "Tap \"Request expanded\" and repeat steps 2 to 6 in expanded. (A4, OQ-10)",
            "Expanded: tap the text field and type, with the on-screen keyboard and a hardware keyboard if you have one. Does the echo follow every key? (A3)",
            "Note anything odd: stickers blank, scroll fighting with peel, menu preview looking wrong, a crash.",
        ]

        var body: some View {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    header
                    stickers
                    Button("Insert A via activeConversation.insert") { probe.insertViaConversation() }
                        .buttonStyle(.bordered)
                    if expanded {
                        textEntry
                    } else {
                        Text("The text field (A3) only shows in expanded: tap \"Request expanded\".")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                    section("What happened") {
                        Text(probe.steps.joined(separator: "\n"))
                            .font(.footnote.monospaced())
                            .textSelection(.enabled)
                    }
                    section("Checklist") {
                        ForEach(Array(Self.checklist.enumerated()), id: \.offset) { index, item in
                            Text("\(index + 1). \(item)").font(.callout)
                        }
                    }
                    eventLog
                }
                .padding()
            }
            .scrollDismissesKeyboard(.interactively)
            .task { probe.prepare() }
        }

        private var header: some View {
            VStack(alignment: .leading, spacing: 8) {
                Text("PROBE: openmoji-25h (debug build only, throwaway)")
                    .font(.headline)
                    .foregroundStyle(.red)
                HStack {
                    Text("Presentation style: \(expanded ? "expanded" : "compact")")
                        .font(.subheadline)
                    Spacer()
                    Button(expanded ? "Request compact" : "Request expanded") {
                        probe.request(expanded ? .compact : .expanded)
                    }
                    .buttonStyle(.bordered)
                    Button("Close probe", action: onClose)
                        .buttonStyle(.borderedProminent)
                }
            }
        }

        private var stickers: some View {
            HStack(alignment: .top, spacing: 16) {
                ProbeStickerCell(probe: probe, title: "A: App Group file, with context menu", outcome: probe.appGroup, withMenu: true)
                ProbeStickerCell(probe: probe, title: "B: App Group file, no menu", outcome: probe.appGroup, withMenu: false)
                ProbeStickerCell(probe: probe, title: "C: bundle file, no menu (control)", outcome: probe.bundle, withMenu: false)
            }
        }

        private var textEntry: some View {
            section("A3: expanded text entry") {
                TextField("Type here", text: $typed)
                    .textFieldStyle(.roundedBorder)
                Text("Echo: \"\(typed)\" (\(typed.count) characters)")
                    .font(.callout.monospaced())
            }
        }

        private var eventLog: some View {
            section("Log") {
                Text(probe.events.isEmpty ? "(nothing yet)" : probe.events.joined(separator: "\n"))
                    .font(.footnote.monospaced())
                    .textSelection(.enabled)
                Button("Clear log") { probe.clearEvents() }
                    .buttonStyle(.bordered)
            }
        }

        private func section(_ title: String, @ViewBuilder content: () -> some View) -> some View {
            VStack(alignment: .leading, spacing: 8) {
                Text(title).font(.headline)
                content()
            }
        }
    }

    /// One `MSStickerView` in a fixed frame, optionally with a SwiftUI context menu.
    /// Branches instead of attaching an empty menu, so the no-menu cells are a
    /// true baseline for the peel gesture.
    private struct ProbeStickerCell: View {
        let probe: ProbeModel
        let title: String
        let outcome: ProbeModel.Outcome
        let withMenu: Bool

        var body: some View {
            VStack(spacing: 6) {
                switch outcome {
                case .sticker(let sticker):
                    if withMenu {
                        ProbeStickerView(sticker: sticker)
                            .frame(width: 120, height: 120)
                            .contextMenu {
                                Button("Probe menu item", systemImage: "hand.tap") {
                                    probe.note("A: context menu item chosen")
                                }
                                Button("Probe destructive item", systemImage: "trash", role: .destructive) {
                                    probe.note("A: destructive context menu item chosen")
                                }
                            }
                    } else {
                        ProbeStickerView(sticker: sticker)
                            .frame(width: 120, height: 120)
                    }
                case .failed(let text):
                    Text(text)
                        .font(.caption2.monospaced())
                        .foregroundStyle(.red)
                        .frame(width: 120, height: 120)
                }
                Text(title)
                    .font(.caption)
                    .multilineTextAlignment(.center)
            }
            .frame(maxWidth: 140)
        }
    }

    private struct ProbeStickerView: UIViewRepresentable {
        let sticker: MSSticker

        func makeUIView(context: Context) -> MSStickerView {
            MSStickerView(frame: .zero, sticker: sticker)
        }

        func updateUIView(_ view: MSStickerView, context: Context) {
            if view.sticker !== sticker { view.sticker = sticker }
        }
    }
#endif
