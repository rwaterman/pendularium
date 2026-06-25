import Metal
import simd

/// Persistent, append-only vertex buffer for accumulated trail segments. Bump-allocated into a
/// single shared `MTLBuffer`; once full the field freezes (we stop extending trails) rather than
/// crash — the graceful end of "until it can't draw any more".
final class TrailBuffer {
    let buffer: MTLBuffer
    let capacity: Int
    private(set) var count: Int = 0
    private let verts: UnsafeMutablePointer<TrailVertex>

    init(device: MTLDevice, capacity: Int) {
        self.capacity = capacity
        let bytes = capacity * MemoryLayout<TrailVertex>.stride
        guard let buf = device.makeBuffer(length: bytes, options: .storageModeShared) else {
            fatalError("Could not allocate \(bytes) byte trail buffer")
        }
        buffer = buf
        verts = buf.contents().bindMemory(to: TrailVertex.self, capacity: capacity)
    }

    var isFull: Bool { count + 2 > capacity }

    /// Clear the painting (used when toggling 2D/3D restarts accumulation).
    func reset() { count = 0 }

    @inline(__always)
    func appendSegment(_ a: SIMD3<Float>, _ b: SIMD3<Float>, attribs: UInt32) {
        guard count + 2 <= capacity else { return }
        verts[count] = TrailVertex(a, attribs: attribs)
        verts[count + 1] = TrailVertex(b, attribs: attribs)
        count += 2
    }
}
