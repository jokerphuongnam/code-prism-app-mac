import SwiftUI

struct InspectorPanel: View {
    @EnvironmentObject private var model: GraphAppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Inspector")
                .font(.headline)

            if let node = model.selectedNode {
                Group {
                    labeled("ID", node.id)
                    labeled("Name", node.name)
                    labeled("Flavor", node.flavor)
                    labeled("File", node.filePath.isEmpty ? "—" : URL(fileURLWithPath: node.filePath).lastPathComponent)
                    labeled("Line", "\(node.line)")
                    Text(node.signature)
                        .font(.system(.caption, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                }

                Divider()

                Text("Outgoing")
                    .font(.subheadline.weight(.semibold))
                let outs = model.document.links.filter { $0.source == node.id }
                if outs.isEmpty {
                    Text("—").foregroundStyle(.tertiary)
                } else {
                    ForEach(outs.prefix(20)) { link in
                        Button(link.target) { model.selectedId = link.target }
                            .buttonStyle(.plain)
                            .foregroundStyle(.tint)
                    }
                }

                Text("Incoming")
                    .font(.subheadline.weight(.semibold))
                    .padding(.top, 6)
                let ins = model.document.links.filter { $0.target == node.id }
                if ins.isEmpty {
                    Text("—").foregroundStyle(.tertiary)
                } else {
                    ForEach(ins.prefix(20)) { link in
                        Button(link.source) { model.selectedId = link.source }
                            .buttonStyle(.plain)
                            .foregroundStyle(.tint)
                    }
                }
            } else {
                Text("Select a node in the 3D graph.")
                    .foregroundStyle(.secondary)
            }

            Spacer()
        }
        .padding(12)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private func labeled(_ title: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title.uppercased())
                .font(.caption2)
                .foregroundStyle(.tertiary)
            Text(value)
                .font(.callout)
                .textSelection(.enabled)
        }
    }
}
