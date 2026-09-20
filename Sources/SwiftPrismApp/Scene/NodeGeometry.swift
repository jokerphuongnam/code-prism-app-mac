import AppKit
import SceneKit
import simd

enum NodeGeometry {
    static func color(for flavor: String) -> NSColor {
        switch flavor.lowercased() {
        case "class", "actor": return .systemBlue
        case "struct", "enum": return .systemTeal
        case "protocol": return .systemPurple
        case "function", "member": return .systemGreen
        case "variable": return .systemOrange
        case "target", "entry_point": return .systemGray
        case "external": return NSColor.systemYellow.withAlphaComponent(0.85)
        default: return .systemIndigo
        }
    }

    static func size(for flavor: String) -> CGFloat {
        switch flavor.lowercased() {
        case "class", "actor", "struct", "enum", "protocol": return 0.55
        case "function", "member": return 0.32
        case "variable": return 0.22
        case "target": return 0.9
        case "external": return 0.28
        default: return 0.35
        }
    }

    static func makeGeometry(flavor: String) -> SCNGeometry {
        let s = size(for: flavor)
        let geo: SCNGeometry
        switch flavor.lowercased() {
        case "struct", "enum", "target":
            geo = SCNBox(width: s, height: s, length: s, chamferRadius: s * 0.08)
        case "protocol":
            geo = SCNPyramid(width: s, height: s, length: s)
        default:
            geo = SCNSphere(radius: s * 0.5)
        }
        let mat = SCNMaterial()
        mat.diffuse.contents = color(for: flavor)
        mat.lightingModel = .physicallyBased
        mat.metalness.contents = 0.15
        mat.roughness.contents = 0.45
        geo.materials = [mat]
        return geo
    }

    static func makeLinkNode(from a: SIMD3<Float>, to b: SIMD3<Float>, kind: String) -> SCNNode {
        let dx = b.x - a.x
        let dy = b.y - a.y
        let dz = b.z - a.z
        let distance = max(sqrt(dx * dx + dy * dy + dz * dz), 0.001)

        let mid = SCNVector3(
            CGFloat((a.x + b.x) * 0.5),
            CGFloat((a.y + b.y) * 0.5),
            CGFloat((a.z + b.z) * 0.5)
        )

        let radius: CGFloat = kind == "call" ? 0.025 : 0.018
        let cylinder = SCNCylinder(radius: radius, height: CGFloat(distance))
        let mat = SCNMaterial()
        if kind == "call" {
            mat.diffuse.contents = NSColor.systemBlue.withAlphaComponent(0.85)
        } else {
            mat.diffuse.contents = NSColor.systemGray.withAlphaComponent(0.55)
        }
        cylinder.materials = [mat]

        let node = SCNNode(geometry: cylinder)
        node.position = mid

        // Align +Y cylinder with direction a→b
        let dir = SIMD3<Float>(dx / distance, dy / distance, dz / distance)
        let up = SIMD3<Float>(0, 1, 0)
        let dotVal = max(-1, min(1, simd_dot(up, dir)))
        let angle = acos(dotVal)
        let axis = simd_cross(up, dir)
        let axisLen = simd_length(axis)
        if axisLen > 0.001 {
            let n = axis / axisLen
            node.rotation = SCNVector4(CGFloat(n.x), CGFloat(n.y), CGFloat(n.z), CGFloat(angle))
        } else if dotVal < 0 {
            node.rotation = SCNVector4(1, 0, 0, CGFloat.pi)
        }
        return node
    }
}
