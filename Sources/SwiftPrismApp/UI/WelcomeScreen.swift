import SwiftUI

struct WelcomeScreen: View {
    @EnvironmentObject private var model: GraphAppModel

    var body: some View {
        VStack(spacing: 28) {
            Image(systemName: "point.3.connected.trianglepath.dotted")
                .font(.system(size: 56))
                .foregroundStyle(.tint)

            Text("Code Prism")
                .font(.largeTitle.weight(.bold))

            Text("Open a project folder. Language backends are detected from plugins on this Mac.\nSoT is stored in the system cache — never inside your project.")
                .font(.body)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 480)

            HStack(spacing: 16) {
                Button {
                    model.openProject()
                } label: {
                    Label("Open Project…", systemImage: "folder")
                        .frame(minWidth: 160)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .keyboardShortcut("o", modifiers: [.command])

                Button("LiteTrace demo") {
                    model.openLiteTraceDemo()
                }
                .controlSize(.large)
            }

            Text("Tip: File → Open… also works.")
                .font(.caption)
                .foregroundStyle(.tertiary)
        }
        .padding(40)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
