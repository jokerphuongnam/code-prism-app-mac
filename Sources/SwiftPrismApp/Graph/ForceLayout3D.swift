import Foundation
import simd

/// Tiny 3D force layout (charge + link + center), enough for LiteTrace-sized graphs.
final class ForceLayout3D {
    private(set) var positions: [String: SIMD3<Float>] = [:]
    private var velocities: [String: SIMD3<Float>] = [:]
    private var links: [(String, String)] = []
    private let ids: [String]

    var charge: Float = -28
    var linkDistance: Float = 3.2
    var linkStrength: Float = 0.06
    var centerStrength: Float = 0.02
    var damping: Float = 0.85

    init(nodeIds: [String], links: [(String, String)]) {
        self.ids = nodeIds
        self.links = links
        // Seed on a sphere so the first frame is not a single clump.
        let n = max(nodeIds.count, 1)
        for (i, id) in nodeIds.enumerated() {
            let t = Float(i) / Float(n) * .pi * 2
            let y = Float(i % 7) * 0.35 - 1.0
            positions[id] = SIMD3(cos(t) * 2.5, y, sin(t) * 2.5)
            velocities[id] = .zero
        }
    }

    @discardableResult
    func tick(_ steps: Int = 1) -> Float {
        var energy: Float = 0
        for _ in 0..<steps {
            var forces = Dictionary(uniqueKeysWithValues: ids.map { ($0, SIMD3<Float>.zero) })

            // Charge (repulsion)
            for i in 0..<ids.count {
                for j in (i + 1)..<ids.count {
                    let a = ids[i], b = ids[j]
                    guard var pa = positions[a], var pb = positions[b] else { continue }
                    var d = pa - pb
                    var dist = length(d)
                    if dist < 0.01 {
                        d = SIMD3(Float.random(in: -0.1...0.1), Float.random(in: -0.1...0.1), Float.random(in: -0.1...0.1))
                        dist = length(d)
                    }
                    let f = (charge / (dist * dist)) * normalize(d)
                    forces[a, default: .zero] += f
                    forces[b, default: .zero] -= f
                }
            }

            // Springs
            for (a, b) in links {
                guard let pa = positions[a], let pb = positions[b] else { continue }
                let d = pb - pa
                let dist = max(length(d), 0.01)
                let f = ((dist - linkDistance) * linkStrength) * normalize(d)
                forces[a, default: .zero] += f
                forces[b, default: .zero] -= f
            }

            // Center
            for id in ids {
                if let p = positions[id] {
                    forces[id, default: .zero] += -p * centerStrength
                }
            }

            // Integrate
            for id in ids {
                var v = (velocities[id] ?? .zero) + (forces[id] ?? .zero)
                v *= damping
                velocities[id] = v
                positions[id, default: .zero] += v
                energy += length_squared(v)
            }
        }
        return energy
    }
}
