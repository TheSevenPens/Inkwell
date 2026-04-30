import Foundation

/// Minimal PSD writer for Phase 9 Pass 1.
///
/// Writes a flat 8-bit RGB+A PSD with no layer hierarchy, no embedded color
/// profile, no image resources. The composite is what Photoshop will open as
/// a single "Background" layer with alpha. Layer-aware export (groups, masks,
/// blend modes round-trip, embedded profile, 16/32-bit channels) is a Phase 9
/// Pass 2 follow-up — see `docs/PSD_FIDELITY.md`.
///
/// Reference: Adobe Photoshop File Format Specification (publicly available).
/// All multi-byte integers in PSD are big-endian.
enum PSDFormat {
    enum PSDError: Error, LocalizedError {
        case invalidPixelCount
        var errorDescription: String? {
            switch self {
            case .invalidPixelCount: "PSD encoder received unexpected pixel-buffer size."
            }
        }
    }

    /// Encode a flat RGBA8 image (premultiplied alpha) as a PSD.
    /// The encoder un-premultiplies internally so Photoshop sees standard alpha semantics.
    /// Pixel rows are top-down (row 0 = top of image), matching the input's storage and PSD's own layout.
    static func encodeFlat(width: Int, height: Int, premultipliedRGBA: [UInt8]) throws -> Data {
        guard premultipliedRGBA.count == width * height * 4 else {
            throw PSDError.invalidPixelCount
        }
        var data = Data()

        // File header (26 bytes).
        data.append(contentsOf: [0x38, 0x42, 0x50, 0x53])  // "8BPS"
        data.append(uint16BE(1))                            // version
        data.append(Data(repeating: 0, count: 6))           // reserved
        data.append(uint16BE(4))                            // channels: R,G,B,A
        data.append(uint32BE(UInt32(height)))
        data.append(uint32BE(UInt32(width)))
        data.append(uint16BE(8))                            // bit depth
        data.append(uint16BE(3))                            // color mode: RGB

        // Color mode data section (empty for RGB).
        data.append(uint32BE(0))

        // Image resources section (empty).
        // Future: profile (resource ID 1039 = ICC profile), thumbnails, etc.
        data.append(uint32BE(0))

        // Layer and mask info section (empty for flat image).
        data.append(uint32BE(0))

        // Image data section.
        data.append(uint16BE(0))                            // compression: 0 = raw

        // Convert interleaved premultiplied RGBA to planar un-premultiplied R, G, B, A.
        let pixelCount = width * height
        var planar = [UInt8](repeating: 0, count: pixelCount * 4)
        for i in 0..<pixelCount {
            let r = premultipliedRGBA[i * 4 + 0]
            let g = premultipliedRGBA[i * 4 + 1]
            let b = premultipliedRGBA[i * 4 + 2]
            let a = premultipliedRGBA[i * 4 + 3]
            let unR: UInt8
            let unG: UInt8
            let unB: UInt8
            if a == 0 {
                unR = 0; unG = 0; unB = 0
            } else {
                unR = UInt8(min(255, Int(r) * 255 / Int(a)))
                unG = UInt8(min(255, Int(g) * 255 / Int(a)))
                unB = UInt8(min(255, Int(b) * 255 / Int(a)))
            }
            planar[0 * pixelCount + i] = unR
            planar[1 * pixelCount + i] = unG
            planar[2 * pixelCount + i] = unB
            planar[3 * pixelCount + i] = a
        }
        data.append(contentsOf: planar)
        return data
    }

    private static func uint16BE(_ v: UInt16) -> Data {
        var b = v.bigEndian
        return withUnsafeBytes(of: &b) { Data($0) }
    }

    private static func uint32BE(_ v: UInt32) -> Data {
        var b = v.bigEndian
        return withUnsafeBytes(of: &b) { Data($0) }
    }
}
