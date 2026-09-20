import SwiftUI

struct ContentView: View {
    @EnvironmentObject private var model: GraphAppModel

    var body: some View {
        NavigationSplitView {
            sidebar
                .frame(minWidth: 220, idealWidth: 260, maxWidth: 320)
        } detail: {
            HSplitView {
                graphPane
                    .frame(minWidth: 500)
                InspectorPanel()
                    .frame(minWidth: 240, idealWidth: 280, maxWidth: 360)
            }
        }
        .toolbar {
            ToolbarItemGroup {
                Button("Open…") { model.openProject() }
                Button("LiteTrace demo") { model.openLiteTraceDemo() }
                Divider()
                Picker("Backend", selection: $model.selectedBackendId) {
                    ForEach(BackendCatalog.all) { b in
                        Text(b.name).tag(b.id)
                    }
                }
                .frame(width: 120)
                Button(model.selectedBackend.isInstalled ? "Reinstall backend" : "Install backend") {
                    model.installSelectedBackend()
                }
                Button("Analyze → SoT") { model.analyze() }
                    .disabled(model.projectRoot == nil || model.isBusy)
                Button("Reload SoT") { model.tryLoadSoT() }
                    .disabled(model.projectRoot == nil || model.isBusy)
            }
        }
        .safeAreaInset(edge: .bottom) {
            HStack {
                if model.isBusy { ProgressView().controlSize(.small) }
                Text(model.status)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                Spacer()
                if let root = model.projectRoot {
                    Text(root.path)
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(.bar)
        }
    }

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 8) {
            TextField("Search symbols", text: $model.searchQuery)
                .textFieldStyle(.roundedBorder)
                .padding(.horizontal, 8)
                .padding(.top, 8)

            List(selection: $model.selectedId) {
                Section("Nodes (\(model.filteredNodes.count))") {
                    ForEach(model.filteredNodes) { node in
                        VStack(alignment: .leading, spacing: 2) {
                            Text(node.name)
                                .font(.body.weight(.medium))
                            Text("\(node.flavor) · \(node.id)")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }
                        .tag(Optional(node.id))
                    }
                }
            }
            .listStyle(.sidebar)
        }
    }

    private var graphPane: some View {
        ZStack {
            if model.document.nodes.isEmpty {
                ContentUnavailableView(
                    "No graph loaded",
                    systemImage: "point.3.connected.trianglepath.dotted",
                    description: Text("Open a project, pick a backend, Analyze. SoT is stored in ~/Library/Caches/code-prism/ (not inside the project).")
                )
            } else {
                GraphSceneView(
                    document: model.document,
                    selectedId: model.selectedId,
                    onSelect: { model.selectedId = $0 }
                )
            }
        }
        .background(Color.black.opacity(0.92))
    }
}
