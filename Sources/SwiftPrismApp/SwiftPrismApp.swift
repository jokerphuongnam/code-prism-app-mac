import SwiftUI

@main
struct SwiftPrismApp: App {
    @StateObject private var model = GraphAppModel()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(model)
                .frame(minWidth: 1100, minHeight: 700)
        }
        .commands {
            // File → Open…
            CommandGroup(replacing: .newItem) {
                Button("Open…") {
                    model.openProject()
                }
                .keyboardShortcut("o", modifiers: [.command])

                Button("Open LiteTrace Demo") {
                    model.openLiteTraceDemo()
                }
                .keyboardShortcut("o", modifiers: [.command, .shift])
            }

            CommandGroup(after: .newItem) {
                Divider()
                Button("Build into Cache…") {
                    if model.screen == .welcome {
                        model.openProject()
                    } else {
                        model.backToBuild()
                    }
                }
                .keyboardShortcut("b", modifiers: [.command])

                Button("Rebuild Graph") {
                    model.analyze(fullBuild: true)
                }
                .keyboardShortcut("r", modifiers: [.command])
                .disabled(!model.canAnalyze)
            }
        }
    }
}
