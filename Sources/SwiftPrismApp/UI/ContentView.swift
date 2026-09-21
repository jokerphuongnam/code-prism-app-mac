import SwiftUI

/// Project window content (build screen or graph). Owned by `ProjectRootView`.
struct ContentView: View {
    @EnvironmentObject private var model: GraphAppModel
    @EnvironmentObject private var bookmarks: BookmarkStore
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Group {
            switch model.screen {
            case .welcome, .build:
                BuildScreen()
            case .graph:
                graphWorkspace
            }
        }
        .toolbar {
            ToolbarItemGroup {
                Button("Projects") {
                    openWindow(id: "bookmarks")
                }
                Button("Open Other…") {
                    if let url = bookmarks.pickAndRemember() {
                        openWindow(id: "project", value: url)
                    }
                }
                if model.screen == .graph {
                    Button("Build…") { model.backToBuild() }
                    Button("Rebuild") { model.analyze(fullBuild: true) }
                        .disabled(!model.canAnalyze)
                    Divider()
                    zoomToolbar
                }
            }
        }
    }

    private var zoomToolbar: some View {
        HStack(spacing: 6) {
            Button {
                model.zoomOut()
            } label: {
                Image(systemName: "minus.magnifyingglass")
            }
            .help("Zoom out (pinch / scroll / toolbar). Double-click a node to focus.")

            Text("\(Int((model.graphZoom * 100).rounded()))%")
                .font(.caption.monospacedDigit())
                .frame(minWidth: 36)

            Button {
                model.zoomIn()
            } label: {
                Image(systemName: "plus.magnifyingglass")
            }
            .help("Zoom in (pinch / scroll / toolbar). Double-click a node to focus.")

            Button("Reset") { model.resetZoom() }
                .disabled(abs(model.graphZoom - 1) < 0.01)
        }
    }

    private var graphWorkspace: some View {
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
        .safeAreaInset(edge: .bottom) {
            HStack {
                if model.isBusy { ProgressView().controlSize(.small) }
                Text(model.status)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                Spacer()
                if !model.detectedLanguages.isEmpty {
                    Text(model.languagesLabel)
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
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

            if model.detectedLanguages.count > 1 {
                Text("Languages: \(model.languagesLabel)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 8)
            }

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
                    description: Text("Go back to Build and run Build into cache.")
                )
            } else {
                GraphMetalView(
                    document: model.document,
                    selectedId: model.selectedId,
                    zoom: model.graphZoom,
                    onSelect: { model.selectedId = $0 },
                    onZoomChange: { model.setGraphZoom($0) }
                )
            }
        }
        .background(Color.black.opacity(0.92))
        .clipped()
    }
}
