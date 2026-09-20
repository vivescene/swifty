import SwiftUI

/// The native application shell. Networking and account authentication are intentionally
/// outside this target for now; this first screen gives those features a stable home.
@main
struct SwiftyApp: App {
    @State private var model = ClientModel()

    var body: some Scene {
        WindowGroup("Swifty") {
            ClientShell(model: model)
                .frame(minWidth: 900, minHeight: 560)
        }
        .commands {
            CommandGroup(after: .windowArrangement) {
                Button("Focus Composer") {
                    model.focusComposer()
                }
                .keyboardShortcut("l", modifiers: [.command, .shift])
                .disabled(model.selectedChannel == nil)
            }
        }
    }
}
