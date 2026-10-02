import SwiftUI

/// The shell app's only screen: explains where to find OpenMoji in Messages.
struct HowToView: View {
    var body: some View {
        VStack(spacing: 16) {
            Text("OpenMoji")
                .font(.largeTitle.bold())
            Text("OpenMoji lives in Messages. Open a conversation, tap the app drawer, and choose OpenMoji.")
                .font(.title3)
                .multilineTextAlignment(.center)
        }
        .padding(32)
    }
}

#Preview {
    HowToView()
}
