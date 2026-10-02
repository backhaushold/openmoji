import Foundation
import Testing

/// Smoke test for the hosted test bundle: `Bundle.main` is the shell app, which
/// must embed the Messages extension.
@Test func hostAppEmbedsMessagesExtension() throws {
    let plugIns = try #require(Bundle.main.builtInPlugInsURL)
    let extensionURL = plugIns.appendingPathComponent("OpenMojiMessages.appex")
    #expect(FileManager.default.fileExists(atPath: extensionURL.path))
}
