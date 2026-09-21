import SwiftUI

/// Shown after opening a project — build / refresh SoT into system cache.
struct BuildScreen: View {
    @EnvironmentObject private var model: GraphAppModel

    var body: some View {
        VStack(spacing: 24) {
            Image(systemName: "shippingbox.fill")
                .font(.system(size: 48))
                .foregroundStyle(.tint)

            Text(model.projectRoot?.lastPathComponent ?? "Project")
                .font(.title.weight(.semibold))

            if model.detectedLanguages.isEmpty {
                Text(model.status)
                    .foregroundStyle(.red)
                    .multilineTextAlignment(.center)
            } else {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Detected languages")
                        .font(.headline)
                    ForEach(model.detectedLanguages, id: \.languageId) { lang in
                        HStack {
                            Image(systemName: "checkmark.circle.fill")
                                .foregroundStyle(.green)
                            Text(BackendCatalog.plugin(id: lang.languageId)?.name ?? lang.languageId)
                                .fontWeight(.medium)
                            Text(lang.evidence)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
                .frame(maxWidth: 480, alignment: .leading)

                Text("Only languages with a Code Prism plugin are detected/built.\nUnknown langs (e.g. Lua without lua-prism) are ignored — no nodes.\nSoT → ~/Library/Caches/code-prism/<project>-<hash>/{lang}-prism/")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 480)

                if model.isBusy {
                    VStack(spacing: 8) {
                        ProgressView(model.buildProgressLabel)
                            .frame(maxWidth: 400)
                        Text("Large monorepos (e.g. private-source) can sit on Swift for a while — prefer opening `marlin-language/` or Cancel.")
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                            .multilineTextAlignment(.center)
                            .frame(maxWidth: 420)
                    }
                }

                HStack(spacing: 12) {
                    Button("Install backend(s)") {
                        model.installSelectedBackend()
                    }
                    .disabled(model.isBusy)

                    Button("Build into cache") {
                        model.analyze(fullBuild: true)
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(!model.canAnalyze)

                    if model.isBusy {
                        Button("Cancel") {
                            model.cancelBuild()
                        }
                        .keyboardShortcut(.cancelAction)
                    }

                    if model.hasCachedGraph {
                        Button("Skip — open graph") {
                            model.showGraph()
                        }
                        .disabled(model.isBusy)
                    }
                }
            }

            if !model.status.isEmpty {
                Text(model.status)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 520)
            }
        }
        .padding(40)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
