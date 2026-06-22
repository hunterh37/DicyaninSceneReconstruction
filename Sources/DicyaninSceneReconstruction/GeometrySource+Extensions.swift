//
//  GeometrySource+Extensions.swift
//  DicyaninSceneReconstruction
//
//  Generic, reusable helpers for reading ARKit mesh geometry buffers.
//  Extracted unchanged in spirit from the original ZombieShooter mesh code,
//  with no game-specific coupling.
//

import ARKit
import RealityKit
import simd

public extension GeometrySource {
    /// Reads the source buffer into a typed array.
    ///
    /// - Important: Must be called on the main queue — `GeometrySource` buffer
    ///   access asserts this.
    func asArray<T>(ofType: T.Type) -> [T] {
        dispatchPrecondition(condition: .onQueue(.main))
        assert(MemoryLayout<T>.stride == stride,
               "Invalid stride \(MemoryLayout<T>.stride); expected \(stride)")
        return (0..<self.count).map {
            buffer.contents()
                .advanced(by: offset + stride * Int($0))
                .assumingMemoryBound(to: T.self).pointee
        }
    }

    /// Reads the source buffer as an array of `SIMD3` vectors.
    func asSIMD3<T>(ofType: T.Type) -> [SIMD3<T>] {
        asArray(ofType: (T, T, T).self).map { .init($0.0, $0.1, $0.2) }
    }
}

public extension MeshAnchor.Geometry {
    /// Returns the surface classification for the face at the given index.
    func classificationOf(faceWithIndex index: Int) -> MeshAnchor.MeshClassification {
        guard let classification = self.classifications else { return .none }
        assert(classification.format == MTLVertexFormat.uchar,
               "Expected one unsigned char (one byte) per classification")
        let pointer = classification.buffer.contents()
            .advanced(by: classification.offset + (classification.stride * index))
        let value = Int(pointer.assumingMemoryBound(to: CUnsignedChar.self).pointee)
        return MeshAnchor.MeshClassification(rawValue: value) ?? .none
    }
}

public extension MeshAnchor {
    /// World-local axis-aligned bounding box derived from the anchor's vertices.
    ///
    /// - Important: Must be called on the main queue (buffer access).
    var boundingBox: BoundingBox {
        self.geometry.vertices
            .asSIMD3(ofType: Float.self)
            .reduce(BoundingBox()) { $0.union($1) }
    }
}
