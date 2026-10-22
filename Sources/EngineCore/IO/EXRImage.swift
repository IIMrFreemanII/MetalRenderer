// The DWA, Huffman, PIZ, ZIP and RLE decoders are ported from OpenEXR 3.3 (OpenEXRCore: internal_dwa*.h,
// internal_huf.c, internal_piz.c, internal_zip.c, internal_rle.c and the generator of dwaLookups.h).
// SPDX-License-Identifier: BSD-3-Clause. Copyright Contributors to the OpenEXR Project.

import Compression
import CoreGraphics
import Foundation
import ImageIO

/// An OpenEXR image read into floats, for the material importer (which turns EXR maps into 16-bit PNGs).
///
/// Single-part scanline files are decoded here, in the compressions OpenEXR writes them with but the rare PXR24 and
/// B44: none, RLE, ZIPS, ZIP, PIZ, and the lossy DWAA and DWAB, which macOS ImageIO can't read (Poly Haven ships its
/// normal and roughness maps as DWAA). The DWA decoder is a port of OpenEXR's own, down to its float arithmetic, so a
/// file decodes to the half floats the library gives. Anything else (tiled, multi-part or deep files, PXR24, B44,
/// subsampled channels) goes to ImageIO, which hands back linear RGBA.
package struct EXRImage {
    package let width: Int
    package let height: Int
    /// Each channel's pixels as floats, row by row from the top (width * height), by channel name ("R", "G", "B", "A", "Y", …).
    package let channels: [String: [Float]]

    package func channel(_ name: String) -> [Float]? { channels[name] }

    package static func read(_ url: URL) throws -> EXRImage {
        let name = url.lastPathComponent
        let data: Data
        do {
            data = try Data(contentsOf: url, options: .alwaysMapped)
        } catch {
            throw MatError("Can't read \(name): \(error.localizedDescription)")
        }
        do {
            return try data.withUnsafeBytes { try EXRDecoder(file: $0).decode() }
        } catch let unsupported as EXRDecoder.Unsupported {
            if let image = readWithImageIO(url) { return image }
            throw MatError("\(name) is \(unsupported.what), which neither the EXR reader nor ImageIO can read")
        } catch let damaged as EXRDecoder.Damaged {
            throw MatError("\(name) is not a readable OpenEXR file: \(damaged.reason)")
        }
    }

    /// The image as ImageIO decodes it, drawn into linear (extended) sRGB floats: R, G, B, and A if it has one.
    static func readWithImageIO(_ url: URL) -> EXRImage? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil),
              let space = CGColorSpace(name: CGColorSpace.extendedLinearSRGB) else { return nil }
        let w = image.width, h = image.height
        guard w > 0, h > 0 else { return nil }
        var rgba = [Float](repeating: 0, count: w * h * 4)
        let drawn = rgba.withUnsafeMutableBytes { bytes -> Bool in
            let info = CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.floatComponents.rawValue
                | CGBitmapInfo.byteOrder32Little.rawValue
            guard let context = CGContext(data: bytes.baseAddress, width: w, height: h, bitsPerComponent: 32,
                                          bytesPerRow: w * 16, space: space, bitmapInfo: info) else { return false }
            context.interpolationQuality = .none
            context.setBlendMode(.copy)
            context.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
            return true
        }
        guard drawn else { return nil }
        let alpha: Bool
        switch image.alphaInfo {
        case .none, .noneSkipFirst, .noneSkipLast: alpha = false
        default: alpha = true
        }
        var channels: [String: [Float]] = [:]
        for (c, name) in ["R", "G", "B", "A"].enumerated() where c < 3 || alpha {
            channels[name] = (0..<w * h).map { rgba[$0 * 4 + c] }
        }
        return EXRImage(width: w, height: h, channels: channels)
    }
}

// MARK: - The file

/// Reads a single-part scanline OpenEXR file that is mapped into memory: its header, then its chunks, decoded in
/// parallel straight from the mapping (each into its own rows of the output).
private struct EXRDecoder {
    /// A file the reader leaves to ImageIO: `what` it is, as in "a tiled EXR".
    struct Unsupported: Error { let what: String }
    /// A file that breaks the format somewhere.
    struct Damaged: Error { let reason: String }

    enum PixelType: Int {
        case uint = 0, half = 1, float = 2
        var size: Int { self == .half ? 2 : 4 }
    }

    struct Channel {
        let name: String
        let type: PixelType
        let linear: Bool
    }

    enum Compression: UInt8 {
        case none = 0, rle = 1, zips = 2, zip = 3, piz = 4, dwaa = 8, dwab = 9

        var linesPerChunk: Int {
            switch self {
            case .none, .rle, .zips: return 1
            case .zip: return 16
            case .piz, .dwaa: return 32
            case .dwab: return 256
            }
        }
    }

    let file: UnsafeRawBufferPointer
    let channels: [Channel]
    let compression: Compression
    let yMin: Int
    let width: Int
    let height: Int
    /// Where the chunk offset table starts.
    let headerEnd: Int

    package init(file: UnsafeRawBufferPointer) throws {
        self.file = file
        var r = ByteReader(bytes: file)
        guard file.count >= 8, try r.u32() == 20000630 else { throw Damaged(reason: "it has no OpenEXR signature") }
        let version = try r.u32()
        guard version & 0xff == 2 else { throw Unsupported(what: "an OpenEXR file of version \(version & 0xff)") }
        if version & 0x1000 != 0 { throw Unsupported(what: "a multi-part EXR") }
        if version & 0x800 != 0 { throw Unsupported(what: "a deep EXR") }
        if version & 0x200 != 0 { throw Unsupported(what: "a tiled EXR") }

        var channels: [Channel]?, compression: UInt8?, window: [Int]?
        while true {
            let attribute = try r.string()
            if attribute.isEmpty { break }
            let type = try r.string()
            let size = Int(try r.i32())
            guard size >= 0, size <= file.count - r.at else { throw Damaged(reason: "attribute \(attribute) is truncated") }
            let start = r.at
            switch (attribute, type) {
            case ("channels", "chlist"):
                var list: [Channel] = []
                var c = ByteReader(bytes: UnsafeRawBufferPointer(rebasing: file[start..<start + size]))
                while true {
                    let name = try c.string()
                    if name.isEmpty { break }
                    let pixelType = Int(try c.i32())
                    let linear = try c.u8() != 0
                    c.at += 3
                    let xSampling = try c.i32(), ySampling = try c.i32()
                    guard let t = PixelType(rawValue: pixelType) else {
                        throw Damaged(reason: "channel \(name) has an unknown pixel type \(pixelType)")
                    }
                    if xSampling != 1 || ySampling != 1 { throw Unsupported(what: "an EXR with subsampled channels") }
                    list.append(Channel(name: name, type: t, linear: linear))
                }
                channels = list
            case ("compression", "compression"):
                guard size >= 1 else { throw Damaged(reason: "the compression attribute is empty") }
                compression = file[start]
            case ("dataWindow", "box2i"):
                var b = ByteReader(bytes: UnsafeRawBufferPointer(rebasing: file[start..<start + size]))
                window = [Int(try b.i32()), Int(try b.i32()), Int(try b.i32()), Int(try b.i32())]
            case ("type", "string"):
                let value = String(decoding: UnsafeRawBufferPointer(rebasing: file[start..<start + size]), as: UTF8.self)
                if value != "scanlineimage" { throw Unsupported(what: "a \(value) EXR") }
            default:
                break
            }
            r.at = start + size
        }
        guard let channels, !channels.isEmpty else { throw Damaged(reason: "it has no channels") }
        guard let compression, let window else { throw Damaged(reason: "its header lacks the compression or data window") }
        guard let method = Compression(rawValue: compression) else {
            let names = [5: "PXR24", 6: "B44", 7: "B44A", 10: "HTJ2K", 11: "HTJ2K"]
            throw Unsupported(what: "an EXR compressed with \(names[Int(compression)] ?? "method \(compression)")")
        }
        let w = window[2] - window[0] + 1, h = window[3] - window[1] + 1
        guard w > 0, h > 0, w <= 1 << 20, h <= 1 << 20, w * h <= 1 << 30 else {
            throw Damaged(reason: "its data window is \(w) x \(h) pixels")
        }
        self.channels = channels
        self.compression = method
        yMin = window[1]
        width = w
        height = h
        headerEnd = r.at
    }

    func decode() throws -> EXRImage {
        let lines = compression.linesPerChunk
        let chunkCount = (height + lines - 1) / lines
        let offsets = try chunkOffsets(chunkCount)
        let pixelCount = width * height
        let outputs = channels.map { _ in UnsafeMutableBufferPointer<Float>.allocate(capacity: pixelCount) }
        defer { outputs.forEach { $0.deallocate() } }

        let lock = NSLock()
        var failure: Error?
        DispatchQueue.concurrentPerform(iterations: chunkCount) { i in
            do {
                try decodeChunk(i, at: offsets[i], into: outputs)
            } catch {
                lock.lock()
                if failure == nil { failure = error }
                lock.unlock()
            }
        }
        if let failure { throw failure }

        var result: [String: [Float]] = [:]
        for (c, channel) in channels.enumerated() { result[channel.name] = Array(outputs[c]) }
        return EXRImage(width: width, height: height, channels: result)
    }

    /// Each chunk's file offset, from the table after the header, or, when the table is damaged (an interrupted
    /// write leaves zeros), by walking the chunks that follow it.
    private func chunkOffsets(_ count: Int) throws -> [Int] {
        let tableEnd = headerEnd + count * 8
        guard tableEnd <= file.count else { throw Damaged(reason: "the chunk table is truncated") }
        var r = ByteReader(bytes: file, at: headerEnd)
        var offsets = try (0..<count).map { _ in Int(truncatingIfNeeded: try r.u64()) }
        if offsets.allSatisfy({ $0 >= tableEnd && $0 <= file.count - 8 }) { return offsets }

        let lines = compression.linesPerChunk
        offsets = [Int](repeating: -1, count: count)
        var at = tableEnd
        while at <= file.count - 8 {
            var c = ByteReader(bytes: file, at: at)
            let y = Int(try c.i32()), size = Int(try c.i32())
            guard size >= 0, size <= file.count - at - 8 else { break }
            let i = (y - yMin) / lines
            if y >= yMin, (y - yMin) % lines == 0, i < count { offsets[i] = at }
            at += 8 + size
        }
        guard !offsets.contains(-1) else { throw Damaged(reason: "the chunk table is damaged and chunks are missing") }
        return offsets
    }

    private func decodeChunk(_ index: Int, at offset: Int, into outputs: [UnsafeMutableBufferPointer<Float>]) throws {
        var r = ByteReader(bytes: file, at: offset)
        let y = Int(try r.i32()), size = Int(try r.i32())
        let lines = compression.linesPerChunk
        guard y == yMin + index * lines else { throw Damaged(reason: "chunk \(index) starts at line \(y)") }
        guard size >= 0, size <= file.count - offset - 8 else { throw Damaged(reason: "chunk \(index) is truncated") }
        let packed = UnsafeRawBufferPointer(rebasing: file[offset + 8..<offset + 8 + size])
        let n = min(lines, height - index * lines)
        let lineBytes = channels.reduce(0) { $0 + $1.type.size } * width
        let unpackedSize = lineBytes * n

        let buffer = UnsafeMutableRawBufferPointer.allocate(byteCount: unpackedSize, alignment: 16)
        defer { buffer.deallocate() }
        if compression == .none || size >= unpackedSize {
            // Stored: a compressor whose output would have been no smaller writes the pixels as they are.
            guard size == unpackedSize else { throw Damaged(reason: "chunk \(index) has \(size) bytes, not \(unpackedSize)") }
            buffer.copyMemory(from: packed)
        } else {
            switch compression {
            case .none: break
            case .rle: try EXRCodecs.undoRLE(packed, into: buffer)
            case .zips, .zip: try EXRCodecs.undoZIP(packed, into: buffer)
            case .piz: try EXRCodecs.undoPIZ(packed, into: buffer, channels: channels, width: width, lines: n)
            case .dwaa, .dwab: try DWADecoder.undo(packed, into: buffer, channels: channels, width: width, lines: n)
            }
        }

        // Interleaved lines (each channel's row in turn) to the output's planes.
        var at = 0
        for line in 0..<n {
            let row = (index * lines + line) * width
            for (c, channel) in channels.enumerated() {
                let out = outputs[c].baseAddress! + row
                let src = buffer.baseAddress! + at
                @inline(__always) func word(_ x: Int) -> UInt32 {
                    UInt32(littleEndian: src.loadUnaligned(fromByteOffset: 4 * x, as: UInt32.self))
                }
                switch channel.type {
                case .half:
                    for x in 0..<width {
                        let h = UInt16(littleEndian: src.loadUnaligned(fromByteOffset: 2 * x, as: UInt16.self))
                        out[x] = Float(Float16(bitPattern: h))
                    }
                case .float:
                    for x in 0..<width { out[x] = Float(bitPattern: word(x)) }
                case .uint:
                    for x in 0..<width { out[x] = Float(word(x)) }
                }
                at += width * channel.type.size
            }
        }
    }
}

/// Little-endian reads with bounds checks.
private struct ByteReader {
    let bytes: UnsafeRawBufferPointer
    var at = 0

    private mutating func load<T: FixedWidthInteger>(_ type: T.Type) throws -> T {
        guard at >= 0, at <= bytes.count - MemoryLayout<T>.size else { throw EXRDecoder.Damaged(reason: "it is truncated") }
        defer { at += MemoryLayout<T>.size }
        return T(littleEndian: bytes.loadUnaligned(fromByteOffset: at, as: T.self))
    }

    mutating func u8() throws -> UInt8 { try load(UInt8.self) }
    mutating func u16() throws -> UInt16 { try load(UInt16.self) }
    mutating func u32() throws -> UInt32 { try load(UInt32.self) }
    mutating func i32() throws -> Int32 { try load(Int32.self) }
    mutating func u64() throws -> UInt64 { try load(UInt64.self) }

    /// A zero-terminated string (EXR names are at most 255 bytes).
    mutating func string() throws -> String {
        let start = at
        while at < bytes.count, bytes[at] != 0, at - start < 256 { at += 1 }
        guard at < bytes.count, bytes[at] == 0 else { throw EXRDecoder.Damaged(reason: "a name is unterminated") }
        defer { at += 1 }
        return String(decoding: UnsafeRawBufferPointer(rebasing: bytes[start..<at]), as: UTF8.self)
    }
}

// MARK: - Lossless codecs

private enum EXRCodecs {
    /// Inflates a zlib stream (Compression's ZLIB is raw deflate, so the two header bytes are skipped) into `out`;
    /// returns the bytes written.
    static func inflate(_ src: UnsafeRawBufferPointer, into out: UnsafeMutableRawBufferPointer) throws -> Int {
        guard out.count > 0 else { return 0 }
        guard src.count > 2, src[0] & 0x0f == 8, src[1] & 0x20 == 0, (Int(src[0]) << 8 | Int(src[1])) % 31 == 0 else {
            throw EXRDecoder.Damaged(reason: "a zlib block has a bad header")
        }
        let written = compression_decode_buffer(out.baseAddress!.assumingMemoryBound(to: UInt8.self), out.count,
                                                src.baseAddress!.assumingMemoryBound(to: UInt8.self) + 2, src.count - 2,
                                                nil, COMPRESSION_ZLIB)
        guard written > 0 else { throw EXRDecoder.Damaged(reason: "a zlib block doesn't inflate") }
        return written
    }

    /// Inflates exactly `out.count` bytes.
    static func inflateExactly(_ src: UnsafeRawBufferPointer, into out: UnsafeMutableRawBufferPointer) throws {
        let written = try inflate(src, into: out)
        guard written == out.count else {
            throw EXRDecoder.Damaged(reason: "a zlib block inflates to \(written) bytes instead of \(out.count)")
        }
    }

    /// The ZIP filters undone (internal_zip_reconstruct_bytes): `source`'s bytes are deltas (plus 128) of the
    /// previous one, and its first half holds the even bytes of `out`, its second half the odd ones.
    static func reconstruct(_ source: UnsafeMutablePointer<UInt8>, into out: UnsafeMutablePointer<UInt8>, count: Int) {
        guard count > 0 else { return }
        var previous = source[0]
        for i in 1..<max(count, 1) {
            previous = previous &+ source[i] &- 128
            source[i] = previous
        }
        let half = (count + 1) / 2
        for i in 0..<count / 2 {
            out[2 * i] = source[i]
            out[2 * i + 1] = source[half + i]
        }
        if count & 1 != 0 { out[count - 1] = source[half - 1] }
    }

    /// OpenEXR's byte run-length code: a negative count -n is followed by n literal bytes, a count n >= 0 by one
    /// byte repeated n + 1 times. Returns the bytes written, or nil if the data overruns either end.
    static func rleDecompress(_ src: UnsafeRawBufferPointer, into out: UnsafeMutablePointer<UInt8>, capacity: Int) -> Int? {
        var i = 0, o = 0
        while i < src.count {
            let n = Int(Int8(bitPattern: src[i]))
            i += 1
            if n < 0 {
                let count = -n
                guard i + count <= src.count, o + count <= capacity else { return nil }
                (out + o).initialize(from: src.baseAddress!.assumingMemoryBound(to: UInt8.self) + i, count: count)
                i += count
                o += count
            } else {
                guard i < src.count, o + n + 1 <= capacity else { return nil }
                (out + o).initialize(repeating: src[i], count: n + 1)
                i += 1
                o += n + 1
            }
        }
        return o
    }

    static func undoRLE(_ packed: UnsafeRawBufferPointer, into out: UnsafeMutableRawBufferPointer) throws {
        let scratch = UnsafeMutablePointer<UInt8>.allocate(capacity: out.count)
        defer { scratch.deallocate() }
        guard rleDecompress(packed, into: scratch, capacity: out.count) == out.count else {
            throw EXRDecoder.Damaged(reason: "an RLE chunk has the wrong size")
        }
        reconstruct(scratch, into: out.baseAddress!.assumingMemoryBound(to: UInt8.self), count: out.count)
    }

    static func undoZIP(_ packed: UnsafeRawBufferPointer, into out: UnsafeMutableRawBufferPointer) throws {
        let scratch = UnsafeMutableRawBufferPointer.allocate(byteCount: out.count, alignment: 16)
        defer { scratch.deallocate() }
        try inflateExactly(packed, into: scratch)
        reconstruct(scratch.baseAddress!.assumingMemoryBound(to: UInt8.self),
                    into: out.baseAddress!.assumingMemoryBound(to: UInt8.self), count: out.count)
    }

    // MARK: PIZ

    /// PIZ (internal_piz.c): a bitmap of the 16-bit values used, Huffman-coded wavelet coefficients of the values'
    /// indices into it, one channel plane after another.
    static func undoPIZ(_ packed: UnsafeRawBufferPointer, into out: UnsafeMutableRawBufferPointer,
                        channels: [EXRDecoder.Channel], width: Int, lines: Int) throws {
        var r = ByteReader(bytes: packed)
        let minNonZero = Int(try r.u16()), maxNonZero = Int(try r.u16())
        let bitmapSize = 8192
        guard maxNonZero < bitmapSize else { throw EXRDecoder.Damaged(reason: "a PIZ chunk has a bad bitmap") }
        var bitmap = [UInt8](repeating: 0, count: bitmapSize)
        if minNonZero <= maxNonZero {
            let n = maxNonZero - minNonZero + 1
            guard r.at + n <= packed.count else { throw EXRDecoder.Damaged(reason: "a PIZ chunk is truncated") }
            for i in 0..<n { bitmap[minNonZero + i] = packed[r.at + i] }
            r.at += n
        }
        // The reverse look-up table: index -> value.
        var lut = [UInt16](repeating: 0, count: 65536)
        var k = 0
        for i in 0..<65536 where i == 0 || bitmap[i >> 3] & (1 << (i & 7)) != 0 {
            lut[k] = UInt16(i)
            k += 1
        }
        let maxValue = UInt16(k - 1)

        let length = Int(try r.u32())
        guard length <= packed.count - r.at else { throw EXRDecoder.Damaged(reason: "a PIZ chunk is truncated") }
        let count = out.count / 2
        let wavelets = UnsafeMutablePointer<UInt16>.allocate(capacity: count)
        defer { wavelets.deallocate() }
        try Huffman.decompress(UnsafeRawBufferPointer(rebasing: packed[r.at..<r.at + length]), into: wavelets, count: count)

        var plane = wavelets
        for channel in channels {
            let words = channel.type.size / 2
            for j in 0..<words {
                waveletDecode(plane + j, nx: width, ox: words, ny: lines, oy: words * width, mx: maxValue)
            }
            plane += width * lines * words
        }
        lut.withUnsafeBufferPointer { lut in
            for i in 0..<count { wavelets[i] = lut[Int(wavelets[i])] }
        }

        // Planes back to interleaved lines.
        var o = out.baseAddress!
        for y in 0..<lines {
            var plane = UnsafeRawPointer(wavelets)
            for channel in channels {
                let rowBytes = width * channel.type.size
                o.copyMemory(from: plane + y * rowBytes, byteCount: rowBytes)
                o += rowBytes
                plane += rowBytes * lines
            }
        }
    }

    /// wav_2D_decode: the inverse of PIZ's 2D Haar-like wavelet, in place on an nx x ny grid with strides ox, oy.
    private static func waveletDecode(_ data: UnsafeMutablePointer<UInt16>, nx: Int, ox: Int, ny: Int, oy: Int, mx: UInt16) {
        let w14 = mx < 1 << 14
        let n = min(nx, ny)
        var p = 1
        while p <= n { p <<= 1 }
        p >>= 1
        var p2 = p
        p >>= 1

        @inline(__always) func wdec14(_ l: UInt16, _ h: UInt16) -> (UInt16, UInt16) {
            let hi = Int(Int16(bitPattern: h)), li = Int(Int16(bitPattern: l))
            let ai = li + (hi & 1) + (hi >> 1)
            return (UInt16(truncatingIfNeeded: ai), UInt16(truncatingIfNeeded: ai - hi))
        }
        @inline(__always) func wdec16(_ l: UInt16, _ h: UInt16) -> (UInt16, UInt16) {
            let m = Int(l), d = Int(h)
            let bb = (m - (d >> 1)) & 0xffff
            let aa = (d + bb - 0x8000) & 0xffff
            return (UInt16(aa), UInt16(bb))
        }
        @inline(__always) func wdec(_ l: UInt16, _ h: UInt16) -> (UInt16, UInt16) { w14 ? wdec14(l, h) : wdec16(l, h) }

        while p >= 1 {
            var py = 0
            let ey = oy * (ny - p2)
            let oy1 = oy * p, oy2 = oy * p2, ox1 = ox * p, ox2 = ox * p2
            while py <= ey {
                var px = py
                let ex = py + ox * (nx - p2)
                while px <= ex {
                    let p01 = px + ox1, p10 = px + oy1, p11 = p10 + ox1
                    if w14 {
                        // wdec14_4
                        let a = Int(Int16(bitPattern: data[px])), b = Int(Int16(bitPattern: data[p10]))
                        let c = Int(Int16(bitPattern: data[p01])), d = Int(Int16(bitPattern: data[p11]))
                        let i00 = a + (b & 1) + (b >> 1)
                        let i10 = i00 - b
                        let i01 = c + (d & 1) + (d >> 1)
                        let i11 = i01 - d
                        let ai = i00 + (i01 & 1) + (i01 >> 1)
                        let bi = ai - i01
                        let ci = i10 + (i11 & 1) + (i11 >> 1)
                        let di = ci - i11
                        data[px] = UInt16(truncatingIfNeeded: ai)
                        data[p01] = UInt16(truncatingIfNeeded: bi)
                        data[p10] = UInt16(truncatingIfNeeded: ci)
                        data[p11] = UInt16(truncatingIfNeeded: di)
                    } else {
                        let (i00, i10) = wdec16(data[px], data[p10])
                        let (i01, i11) = wdec16(data[p01], data[p11])
                        (data[px], data[p01]) = wdec16(i00, i01)
                        (data[p10], data[p11]) = wdec16(i10, i11)
                    }
                    px += ox2
                }
                if nx & p != 0 {
                    let p10 = px + oy1
                    (data[px], data[p10]) = wdec(data[px], data[p10])
                }
                py += oy2
            }
            if ny & p != 0 {
                var px = py
                let ex = py + ox * (nx - p2)
                while px <= ex {
                    let p01 = px + ox1
                    (data[px], data[p01]) = wdec(data[px], data[p01])
                    px += ox2
                }
            }
            p2 = p
            p >>= 1
        }
    }
}

// MARK: - Huffman

/// OpenEXR's static Huffman code (internal_huf.c, the classic decoder): a packed table of code lengths for the
/// symbols im...iM, canonical codes, and the symbol iM standing for "repeat the last value n more times".
private enum Huffman {
    static let encodingSize = 65537
    static let decodingBits = 14
    static let decodingSize = 1 << decodingBits
    static let shortZerocodeRun = 59
    static let longZerocodeRun = 63
    static let shortestLongRun = 2 + longZerocodeRun - shortZerocodeRun

    static func decompress(_ src: UnsafeRawBufferPointer, into out: UnsafeMutablePointer<UInt16>, count: Int) throws {
        guard src.count >= 20 else {
            guard count == 0 else { throw EXRDecoder.Damaged(reason: "a Huffman block is truncated") }
            return
        }
        var r = ByteReader(bytes: src)
        let im = Int(try r.u32()), iM = Int(try r.u32())
        _ = try r.u32()
        let nBits = Int(try r.u32())
        guard im < encodingSize, iM < encodingSize, im <= iM else { throw EXRDecoder.Damaged(reason: "a Huffman table is bad") }
        guard 20 + (nBits + 7) / 8 <= src.count else { throw EXRDecoder.Damaged(reason: "a Huffman block is truncated") }

        var codes = [UInt64](repeating: 0, count: encodingSize)
        var at = 20
        try unpackEncodingTable(src, at: &at, im: im, iM: iM, into: &codes)
        guard nBits <= 8 * (src.count - at) else { throw EXRDecoder.Damaged(reason: "a Huffman block is truncated") }
        try codes.withUnsafeBufferPointer { codes in
            let table = try DecodingTable(codes: codes, im: im, iM: iM)
            try decode(codes: codes, table: table, src.baseAddress! + at, bits: nBits, rlc: UInt32(iM),
                       into: out, count: count)
        }
    }

    /// hufUnpackEncTable + hufCanonicalCodeTable: 6-bit code lengths (59...62 a short run of zero lengths, 63 then
    /// 8 bits a long one), then each symbol's canonical code, stored as code << 6 | length.
    private static func unpackEncodingTable(_ src: UnsafeRawBufferPointer, at: inout Int, im: Int, iM: Int,
                                            into codes: inout [UInt64]) throws {
        var c: UInt64 = 0, lc = 0
        func bits(_ n: Int) throws -> UInt64 {
            while lc < n {
                guard at < src.count else { throw EXRDecoder.Damaged(reason: "a Huffman table is truncated") }
                c = c << 8 | UInt64(src[at])
                at += 1
                lc += 8
            }
            lc -= n
            return (c >> UInt64(lc)) & ((1 << UInt64(n)) - 1)
        }
        var i = im
        while i <= iM {
            let l = Int(try bits(6))
            codes[i] = UInt64(l)
            if l == longZerocodeRun {
                let run = Int(try bits(8)) + shortestLongRun
                guard i + run <= iM + 1 else { throw EXRDecoder.Damaged(reason: "a Huffman table is bad") }
                for j in i..<i + run { codes[j] = 0 }
                i += run
            } else if l >= shortZerocodeRun {
                let run = l - shortZerocodeRun + 2
                guard i + run <= iM + 1 else { throw EXRDecoder.Damaged(reason: "a Huffman table is bad") }
                for j in i..<i + run { codes[j] = 0 }
                i += run
            } else {
                i += 1
            }
        }

        // Canonical codes: shorter codes are numerically higher, codes of one length increase with the symbol.
        var n = [UInt64](repeating: 0, count: 59)
        for l in codes { n[Int(l)] += 1 }
        var code: UInt64 = 0
        for l in stride(from: 58, to: 0, by: -1) {
            let next = (code + n[l]) >> 1
            n[l] = code
            code = next
        }
        for s in 0..<encodingSize where codes[s] > 0 {
            let l = Int(codes[s])
            codes[s] = UInt64(l) | n[l] << 6
            n[l] += 1
        }
    }

    /// hufBuildDecTable: codes of up to 14 bits are resolved by one look-up of the next 14 bits; a longer code's
    /// entry (for its first 14 bits) lists the symbols to try.
    private struct DecodingTable {
        var length: [Int32]
        var symbol: [UInt32]           // a short code's symbol; for long codes, how many share the entry
        var longStart: [Int32]         // where an entry's long-code symbols start in `longSymbols`
        var longSymbols: [UInt32]

        package init(codes: UnsafeBufferPointer<UInt64>, im: Int, iM: Int) throws {
            let size = Huffman.decodingSize, bits = Huffman.decodingBits
            length = [Int32](repeating: 0, count: size)
            symbol = [UInt32](repeating: 0, count: size)
            longStart = [Int32](repeating: 0, count: size)
            var longCount = [Int32](repeating: 0, count: size)
            for i in im...iM {
                let c = codes[i] >> 6, l = Int(codes[i] & 63)
                guard c >> UInt64(l) == 0 else { throw EXRDecoder.Damaged(reason: "a Huffman code is bad") }
                if l > bits {
                    longCount[Int(c >> UInt64(l - bits))] += 1
                } else if l > 0 {
                    let first = Int(c << UInt64(bits - l))
                    for e in first..<first + (1 << (bits - l)) {
                        guard length[e] == 0, longCount[e] == 0 else {
                            throw EXRDecoder.Damaged(reason: "a Huffman code is bad")
                        }
                        length[e] = Int32(l)
                        symbol[e] = UInt32(i)
                    }
                }
            }
            var total: Int32 = 0
            for e in 0..<size {
                if longCount[e] > 0 && length[e] != 0 { throw EXRDecoder.Damaged(reason: "a Huffman code is bad") }
                longStart[e] = total
                total += longCount[e]
            }
            longSymbols = [UInt32](repeating: 0, count: Int(total))
            var filled = [Int32](repeating: 0, count: size)
            for i in im...iM {
                let c = codes[i] >> 6, l = Int(codes[i] & 63)
                if l > bits {
                    let e = Int(c >> UInt64(l - bits))
                    longSymbols[Int(longStart[e] + filled[e])] = UInt32(i)
                    filled[e] += 1
                }
            }
            for e in 0..<size where longCount[e] > 0 { symbol[e] = UInt32(longCount[e]) }
        }
    }

    /// hufDecode.
    private static func decode(codes: UnsafeBufferPointer<UInt64>, table: DecodingTable, _ input: UnsafeRawPointer,
                               bits nBits: Int, rlc: UInt32, into out: UnsafeMutablePointer<UInt16>, count: Int) throws {
        let bad = EXRDecoder.Damaged(reason: "a Huffman block is corrupt")
        let mask = UInt64(decodingSize - 1), decBits = decodingBits
        let ie = (nBits + 7) / 8
        let input = input.assumingMemoryBound(to: UInt8.self)
        var c: UInt64 = 0, lc = 0, i = 0, o = 0

        try table.length.withUnsafeBufferPointer { length in
        try table.symbol.withUnsafeBufferPointer { symbol in
        try table.longStart.withUnsafeBufferPointer { longStart in
        try table.longSymbols.withUnsafeBufferPointer { longSymbols in
            @inline(__always) func put(_ po: UInt32) throws {
                if po == rlc {
                    if lc < 8 {
                        guard i < ie else { throw bad }
                        c = c << 8 | UInt64(input[i])
                        i += 1
                        lc += 8
                    }
                    lc -= 8
                    let cs = Int(UInt8(truncatingIfNeeded: c >> UInt64(lc)))
                    guard o + cs <= count, o >= 1 else { throw bad }
                    let s = out[o - 1]
                    for k in 0..<cs { out[o + k] = s }
                    o += cs
                } else {
                    guard o < count else { throw bad }
                    out[o] = UInt16(truncatingIfNeeded: po)
                    o += 1
                }
            }

            while i < ie {
                c = c << 8 | UInt64(input[i])
                i += 1
                lc += 8
                while lc >= decBits {
                    let e = Int((c >> UInt64(lc - decBits)) & mask)
                    let l = Int(length[e])
                    if l != 0 {
                        guard l <= lc else { throw bad }
                        lc -= l
                        try put(symbol[e])
                    } else {
                        let n = Int(symbol[e])
                        guard n > 0 else { throw bad }
                        var found = false
                        for j in 0..<n {
                            let s = Int(longSymbols[Int(longStart[e]) + j])
                            let l = Int(codes[s] & 63)
                            while lc < l && i < ie {
                                c = c << 8 | UInt64(input[i])
                                i += 1
                                lc += 8
                            }
                            if lc >= l, codes[s] >> 6 == (c >> UInt64(lc - l)) & ((1 << UInt64(l)) - 1) {
                                lc -= l
                                try put(UInt32(s))
                                found = true
                                break
                            }
                        }
                        guard found else { throw bad }
                    }
                }
            }

            // The last (short) codes.
            let skip = (8 - nBits) & 7
            c >>= UInt64(skip)
            lc -= skip
            while lc > 0 {
                let e = Int((c << UInt64(decBits - lc)) & mask)
                let l = Int(length[e])
                guard l != 0, l <= lc else { throw bad }
                lc -= l
                try put(symbol[e])
            }
        }}}}
        guard o == count else { throw bad }
    }
}

// MARK: - DWA

/// OpenEXR's DWAA and DWAB (internal_dwa_compressor.h, internal_dwa_decoder.h): channels are classified by name,
/// and R, G, B and Y (half or float) are stored lossy as 8 x 8 DCT blocks of a perceptual (and, for R, G, B together,
/// Y'CbCr) encoding of the values, A is run-length coded, anything else zlib-compressed. DWAA chunks are 32 lines,
/// DWAB 256; the decoder is the same.
private enum DWADecoder {
    enum Scheme: Int { case unknown = 0, lossyDCT = 1, rle = 2 }

    /// A channel rule: a channel whose name ends in `suffix` (after its last '.') and has pixels of `type` is coded
    /// with `scheme`, as component `csc` (0, 1, 2 for R, G, B; -1 none) of a colour set.
    struct Rule {
        package let suffix: [UInt8]
        package let scheme: Scheme
        package let type: Int
        package let csc: Int
        package let caseInsensitive: Bool

        package func matches(_ name: ArraySlice<UInt8>, _ pixelType: EXRDecoder.PixelType) -> Bool {
            guard type == pixelType.rawValue, name.count == suffix.count else { return false }
            if !caseInsensitive { return name.elementsEqual(suffix) }
            return zip(name, suffix).allSatisfy { lower($0) == lower($1) }
        }

        private func lower(_ c: UInt8) -> UInt8 { c >= 65 && c <= 90 ? c + 32 : c }
    }

    /// The rules of files before version 2, which don't carry their own.
    static let legacyRules: [Rule] = {
        var rules: [Rule] = []
        func add(_ s: String, _ scheme: Scheme, _ csc: Int, _ types: [Int]) {
            for t in types {
                rules.append(Rule(suffix: Array(s.utf8), scheme: scheme, type: t, csc: csc, caseInsensitive: true))
            }
        }
        for s in ["r", "red"] { add(s, .lossyDCT, 0, [1, 2]) }
        for s in ["g", "grn", "green"] { add(s, .lossyDCT, 1, [1, 2]) }
        for s in ["b", "blu", "blue"] { add(s, .lossyDCT, 2, [1, 2]) }
        for s in ["y", "by", "ry"] { add(s, .lossyDCT, -1, [1, 2]) }
        add("a", .rle, -1, [0, 1, 2])
        return rules
    }()

    static func undo(_ src: UnsafeRawBufferPointer, into out: UnsafeMutableRawBufferPointer,
                     channels: [EXRDecoder.Channel], width: Int, lines: Int) throws {
        func damaged(_ why: String) -> EXRDecoder.Damaged { EXRDecoder.Damaged(reason: "a DWA chunk \(why)") }
        out.initializeMemory(as: UInt8.self, repeating: 0)

        // The header: eleven Xdr (little-endian) 64-bit counts.
        let headerSize = 11 * 8
        guard src.count >= headerSize else { throw damaged("is truncated") }
        var r = ByteReader(bytes: src)
        var counts = [Int]()
        for _ in 0..<11 {
            let v = try r.u64()
            guard v <= UInt64(Int.max / 4) else { throw damaged("has a bad size") }
            counts.append(Int(v))
        }
        let version = counts[0]
        let unknownUncompressedSize = counts[1], unknownCompressedSize = counts[2]
        let acCompressedSize = counts[3], dcCompressedSize = counts[4]
        let rleCompressedSize = counts[5], rleUncompressedSize = counts[6], rleRawSize = counts[7]
        let totalAcCount = counts[8]
        var totalDcCount = counts[9]
        let acCompression = counts[10]
        guard unknownCompressedSize + acCompressedSize + dcCompressedSize + rleCompressedSize <= src.count - headerSize else {
            throw damaged("is truncated")
        }
        guard version <= 2 else { throw damaged("has an unknown version \(version)") }

        // Channel rules: in the chunk from version 2.
        var rules = legacyRules
        if version >= 2 {
            let ruleSize = Int(try r.u16())
            guard ruleSize >= 2, ruleSize <= src.count - headerSize else { throw damaged("has bad channel rules") }
            rules = []
            var p = headerSize + 2
            let end = headerSize + ruleSize
            while p < end {
                var q = p
                while q < end, src[q] != 0 { q += 1 }
                guard q - p <= 128, q + 3 <= end else { throw damaged("has bad channel rules") }
                let value = Int(src[q + 1]), type = Int(src[q + 2])
                let csc = (value >> 4) - 1
                guard csc >= -1, csc < 3, let scheme = Scheme(rawValue: (value >> 2) & 3), type < 3 else {
                    throw damaged("has bad channel rules")
                }
                rules.append(Rule(suffix: Array(src[p..<q]), scheme: scheme, type: type, csc: csc,
                                  caseInsensitive: value & 1 != 0))
                p = q + 3
            }
            r.at = end
        }
        let dataStart = r.at
        guard unknownCompressedSize + acCompressedSize + dcCompressedSize + rleCompressedSize <= src.count - dataStart else {
            throw damaged("is truncated")
        }

        // Classify the channels; group R, G, B of one layer (name prefix) into colour sets.
        var schemes = [Scheme](repeating: .unknown, count: channels.count)
        var prefixes: [(prefix: ArraySlice<UInt8>, idx: [Int])] = []
        for (c, channel) in channels.enumerated() {
            let name = Array(channel.name.utf8)[...]
            let dot = name.lastIndex(of: UInt8(ascii: ".")).map { $0 + 1 } ?? 0
            let prefix = name[..<dot], suffix = name[dot...]
            var set = prefixes.firstIndex { $0.prefix.elementsEqual(prefix) }
            if set == nil {
                prefixes.append((prefix, [-1, -1, -1]))
                set = prefixes.count - 1
            }
            for rule in rules where rule.matches(suffix, channel.type) {
                schemes[c] = rule.scheme
                if rule.csc >= 0 { prefixes[set!].idx[rule.csc] = c }
            }
        }
        let cscSets = prefixes.map(\.idx).filter { !$0.contains(-1) }

        // Buffer limits, as the library's: blocks of every lossy channel, twice the pixels for RLE.
        let blocks = ((lines + 7) / 8) * ((width + 7) / 8)
        let lossyCount = schemes.filter { $0 == .lossyDCT }.count
        var unknownBytes = 0, rleBytes = 0
        for (c, channel) in channels.enumerated() {
            if schemes[c] == .unknown { unknownBytes += width * lines * channel.type.size }
            if schemes[c] == .rle { rleBytes += width * lines * channel.type.size }
        }
        guard totalAcCount <= blocks * 63 * lossyCount, totalDcCount <= blocks * lossyCount,
              unknownUncompressedSize <= unknownBytes + unknownBytes / 1000 + 1024,
              rleUncompressedSize <= 2 * rleBytes, rleRawSize <= 2 * rleBytes else { throw damaged("has bad sizes") }

        var at = dataStart
        func take(_ n: Int) -> UnsafeRawBufferPointer {
            defer { at += n }
            return UnsafeRawBufferPointer(rebasing: src[at..<at + n])
        }
        let unknownSource = take(unknownCompressedSize), acSource = take(acCompressedSize)
        let dcSource = take(dcCompressedSize), rleSource = take(rleCompressedSize)

        // UNKNOWN channels: one zlib block of their planes.
        let unknown = UnsafeMutableRawBufferPointer.allocate(byteCount: max(unknownUncompressedSize, 1), alignment: 16)
        defer { unknown.deallocate() }
        var unknownLength = 0
        if unknownCompressedSize > 0 {
            let into = UnsafeMutableRawBufferPointer(rebasing: unknown[0..<unknownUncompressedSize])
            unknownLength = try EXRCodecs.inflate(unknownSource, into: into)
        }

        // AC coefficients: static Huffman or zlib.
        let ac = UnsafeMutablePointer<UInt16>.allocate(capacity: max(totalAcCount, 1))
        defer { ac.deallocate() }
        if acCompressedSize > 0 {
            switch acCompression {
            case 0:
                try Huffman.decompress(acSource, into: ac, count: totalAcCount)
            case 1:
                let into = UnsafeMutableRawBufferPointer(start: ac, count: totalAcCount * 2)
                try EXRCodecs.inflateExactly(acSource, into: into)
                for i in 0..<totalAcCount { ac[i] = UInt16(littleEndian: ac[i]) }
            default:
                throw damaged("has an unknown AC compression \(acCompression)")
            }
        } else {
            ac.initialize(repeating: 0, count: max(totalAcCount, 1))
        }

        // DC coefficients: zlib with the ZIP filters.
        let dc = UnsafeMutablePointer<UInt16>.allocate(capacity: max(totalDcCount, 1))
        defer { dc.deallocate() }
        if dcCompressedSize > 0 {
            let bytes = totalDcCount * 2
            let scratch = UnsafeMutableRawBufferPointer.allocate(byteCount: max(bytes, 1), alignment: 16)
            defer { scratch.deallocate() }
            try EXRCodecs.inflateExactly(dcSource, into: UnsafeMutableRawBufferPointer(rebasing: scratch[0..<bytes]))
            EXRCodecs.reconstruct(scratch.baseAddress!.assumingMemoryBound(to: UInt8.self),
                                  into: UnsafeMutableRawPointer(dc).assumingMemoryBound(to: UInt8.self), count: bytes)
            for i in 0..<totalDcCount { dc[i] = UInt16(littleEndian: dc[i]) }
        } else if totalDcCount != 0 {
            throw damaged("lacks its DC coefficients")
        }

        // RLE channels: zlib, then run-length coded byte planes.
        let rle = UnsafeMutablePointer<UInt8>.allocate(capacity: max(rleRawSize, 1))
        defer { rle.deallocate() }
        if rleRawSize > 0 {
            let packed = UnsafeMutableRawBufferPointer.allocate(byteCount: max(rleUncompressedSize, 1), alignment: 16)
            defer { packed.deallocate() }
            try EXRCodecs.inflateExactly(rleSource, into: UnsafeMutableRawBufferPointer(rebasing: packed[0..<rleUncompressedSize]))
            guard EXRCodecs.rleDecompress(UnsafeRawBufferPointer(rebasing: packed[0..<rleUncompressedSize]), into: rle,
                                          capacity: rleRawSize) == rleRawSize else { throw damaged("has bad RLE data") }
        }

        // Where each channel's row y starts in `out`: lines of every channel's row in turn.
        let lineBytes = channels.reduce(0) { $0 + $1.type.size } * width
        var channelOffset = [Int](), offset = 0
        for channel in channels {
            channelOffset.append(offset)
            offset += width * channel.type.size
        }
        let base = out.baseAddress!
        func rows(_ c: Int) -> DCTRows { DCTRows(start: base + channelOffset[c], stride: lineBytes, type: channels[c].type) }

        var acUsed = 0, dcUsed = 0
        let toLinear = EXRImage.dwaToLinear
        try toLinear.withUnsafeBufferPointer { toLinear in
            var processed = [Bool](repeating: false, count: channels.count)
            for set in cscSets {
                guard set.allSatisfy({ schemes[$0] == .lossyDCT }) else { throw damaged("has a bad colour set") }
                try decodeLossyDCT(set.map(rows), width: width, height: lines,
                                   ac: ac + acUsed, acCount: totalAcCount - acUsed, acUsed: &acUsed,
                                   dc: dc + dcUsed, dcCount: totalDcCount, dcUsed: &dcUsed, toLinear: toLinear.baseAddress)
                totalDcCount = counts[9] - dcUsed
                for c in set { processed[c] = true }
            }

            var unknownAt = 0, rleAt = 0
            for (c, channel) in channels.enumerated() where !processed[c] {
                let size = channel.type.size, rowBytes = width * size
                switch schemes[c] {
                case .lossyDCT:
                    try decodeLossyDCT([rows(c)], width: width, height: lines,
                                       ac: ac + acUsed, acCount: totalAcCount - acUsed, acUsed: &acUsed,
                                       dc: dc + dcUsed, dcCount: totalDcCount, dcUsed: &dcUsed,
                                       toLinear: channel.linear ? nil : toLinear.baseAddress)
                    totalDcCount = counts[9] - dcUsed
                case .rle:
                    // Byte planes: every pixel's first byte, then every second byte...
                    let planeSize = width * lines
                    guard rleAt + planeSize * size <= rleRawSize else { throw damaged("has too little RLE data") }
                    for y in 0..<lines {
                        let dst = (base + channelOffset[c] + y * lineBytes).assumingMemoryBound(to: UInt8.self)
                        for x in 0..<width {
                            for byte in 0..<size { dst[x * size + byte] = rle[rleAt + byte * planeSize + y * width + x] }
                        }
                    }
                    rleAt += planeSize * size
                case .unknown:
                    guard unknownAt + rowBytes * lines <= unknownLength else { throw damaged("has too little zlib data") }
                    for y in 0..<lines {
                        let dst = base + channelOffset[c] + y * lineBytes
                        dst.copyMemory(from: unknown.baseAddress! + unknownAt, byteCount: rowBytes)
                        unknownAt += rowBytes
                    }
                }
            }
        }
    }

    /// A channel's rows in the chunk: row y starts at `start + y * stride`.
    struct DCTRows {
        let start: UnsafeMutableRawPointer
        let stride: Int
        let type: EXRDecoder.PixelType
    }

    /// The zig-zag order: `zigZag[i]` is the zig-zag index of the coefficient at row-major position i.
    static let zigZag: [Int] = [
        0, 1, 5, 6, 14, 15, 27, 28, 2, 4, 7, 13, 16, 26, 29, 42,
        3, 8, 12, 17, 25, 30, 41, 43, 9, 11, 18, 24, 31, 40, 44, 53,
        10, 19, 23, 32, 39, 45, 52, 54, 20, 22, 33, 38, 46, 51, 55, 60,
        21, 34, 37, 47, 50, 56, 59, 61, 35, 36, 48, 49, 57, 58, 62, 63,
    ]

    /// LossyDctDecoder_execute: one channel, or a colour set of three decoded together (Y'CbCr to R'G'B'), block
    /// row by block row: DC and run-length-coded AC to an 8 x 8 block, the inverse DCT, the colour transform, to
    /// half, and through `toLinear` (nil: as they are) into the rows. Float channels are widened at the end.
    static func decodeLossyDCT(_ channels: [DCTRows], width: Int, height: Int,
                               ac: UnsafePointer<UInt16>, acCount: Int, acUsed: inout Int,
                               dc: UnsafePointer<UInt16>, dcCount: Int, dcUsed: inout Int,
                               toLinear: UnsafePointer<UInt16>?) throws {
        let bad = EXRDecoder.Damaged(reason: "a DWA chunk has bad DCT data")
        let numComp = channels.count
        let numBlocksX = (width + 7) / 8, numBlocksY = (height + 7) / 8
        let leftoverX = width - (numBlocksX - 1) * 8, leftoverY = height - (numBlocksY - 1) * 8
        let numFullBlocksX = width / 8
        guard dcCount >= numComp * numBlocksX * numBlocksY else { throw bad }

        let rowBlock = UnsafeMutablePointer<UInt16>.allocate(capacity: numComp * numBlocksX * 64)
        let halfZig = UnsafeMutablePointer<UInt16>.allocate(capacity: numComp * 64)
        let dct = UnsafeMutablePointer<Float>.allocate(capacity: numComp * 64)
        defer {
            rowBlock.deallocate()
            halfZig.deallocate()
            dct.deallocate()
        }
        let identity = toLinear == nil
        let lut = toLinear ?? UnsafePointer(rowBlock)  // unused when identity

        var acAt = 0, dcRead = 0
        try zigZag.withUnsafeBufferPointer { zigZag in
            for blockY in 0..<numBlocksY {
                let maxY = blockY == numBlocksY - 1 ? leftoverY : 8
                for blockX in 0..<numBlocksX {
                    var blockIsConstant = true
                    for comp in 0..<numComp {
                        let zig = halfZig + comp * 64, data = dct + comp * 64
                        zig.initialize(repeating: 0, count: 64)
                        // Each component's DC values are a plane of their own.
                        zig[0] = dc[comp * numBlocksX * numBlocksY + blockY * numBlocksX + blockX]
                        dcRead += 1

                        // The AC run-length code: 0xff00 ends the block, 0xffnn skips nn zeros.
                        var i = 1, lastNonZero = 0
                        while i < 64 {
                            guard acAt < acCount else { throw bad }
                            let v = ac[acAt]
                            if v == 0xff00 {
                                i = 64
                            } else if v >> 8 == 0xff {
                                i += Int(v & 0xff)
                            } else {
                                lastNonZero = i
                                zig[i] = v
                                i += 1
                            }
                            acAt += 1
                        }

                        if lastNonZero == 0 {
                            let v = Float(Float16(bitPattern: zig[0])) * 3.535536e-01 * 3.535536e-01
                            data.initialize(repeating: v, count: 64)
                        } else {
                            blockIsConstant = false
                            for k in 0..<64 { data[k] = Float(Float16(bitPattern: zig[zigZag[k]])) }
                            // Rows past the last non-zero coefficient's are zero: lastNonZero below the zig-zag
                            // index of row r's first coefficient (2, 3, 9, 10, 20, 21, 35) leaves 8 - r rows empty.
                            let zeroedRows: Int
                            switch lastNonZero {
                            case ..<2: zeroedRows = 7
                            case ..<3: zeroedRows = 6
                            case ..<9: zeroedRows = 5
                            case ..<10: zeroedRows = 4
                            case ..<20: zeroedRows = 3
                            case ..<21: zeroedRows = 2
                            case ..<35: zeroedRows = 1
                            default: zeroedRows = 0
                            }
                            inverseDCT(data, zeroedRows: zeroedRows)
                        }
                    }

                    if numComp == 3 {
                        inverseCSC(dct, dct + 64, dct + 128, count: blockIsConstant ? 1 : 64)
                    }

                    for comp in 0..<numComp {
                        let dst = rowBlock + comp * numBlocksX * 64 + blockX * 64, data = dct + comp * 64
                        if blockIsConstant {
                            dst.initialize(repeating: Float16(data[0]).bitPattern, count: 64)
                        } else {
                            for k in 0..<64 { dst[k] = Float16(data[k]).bitPattern }
                        }
                    }
                }

                // Unblock the block row, through the curve back to linear.
                for comp in 0..<numComp {
                    let rows = channels[comp], block = rowBlock + comp * numBlocksX * 64
                    for y in 8 * blockY..<8 * blockY + maxY {
                        let dst = (rows.start + y * rows.stride).assumingMemoryBound(to: UInt16.self)
                        for blockX in 0..<numBlocksX {
                            let src = block + blockX * 64 + (y & 7) * 8
                            let n = blockX < numFullBlocksX ? 8 : leftoverX
                            for x in 0..<n {
                                let v = src[x]
                                dst[blockX * 8 + x] = (identity ? v : lut[Int(v)]).littleEndian
                            }
                        }
                    }
                }
            }
        }

        // Float channels: the halves widened in place, from the end of each row.
        for rows in channels where rows.type == .float {
            for y in 0..<height {
                let row = rows.start + y * rows.stride
                for x in stride(from: width - 1, through: 0, by: -1) {
                    let h = UInt16(littleEndian: row.load(fromByteOffset: 2 * x, as: UInt16.self))
                    let f = Float(Float16(bitPattern: h)).bitPattern.littleEndian
                    row.storeBytes(of: f, toByteOffset: 4 * x, as: UInt32.self)
                }
            }
        }
        acUsed += acAt
        dcUsed += dcRead
    }

    // The float arithmetic of OpenEXR's scalar inverse DCT and colour transform as clang builds it for arm64, which
    // contracts a * b + c within one expression into a fused multiply-add (clang's default): the same operations,
    // fused the same way, in the same order, so blocks decode to the library's bits. (Unfused, about 1 value in
    // 60,000 of a 4K normal map came out up to 4 half steps away from the library's arm64 decode.)
    @inline(__always) private static func madd(_ a: Float, _ b: Float, _ c: Float) -> Float { c.addingProduct(a, b) }

    private static let a: Float = 0.5 * cosf(3.14159 / 4)
    private static let b: Float = 0.5 * cosf(3.14159 / 16)
    private static let c: Float = 0.5 * cosf(3.14159 / 8)
    private static let d: Float = 0.5 * cosf(3 * 3.14159 / 16)
    private static let e: Float = 0.5 * cosf(5 * 3.14159 / 16)
    private static let f: Float = 0.5 * cosf(3 * 3.14159 / 8)
    private static let g: Float = 0.5 * cosf(7 * 3.14159 / 16)

    /// dctInverse8x8_scalar: rows (the last `zeroedRows` are zero and stay so), then columns.
    static func inverseDCT(_ data: UnsafeMutablePointer<Float>, zeroedRows: Int) {
        let a = Self.a, b = Self.b, c = Self.c, d = Self.d, e = Self.e, f = Self.f, g = Self.g

        @inline(__always) func pass(_ p: UnsafeMutablePointer<Float>, _ s: Int) {
            let r0 = p[0], r1 = p[s], r2 = p[2 * s], r3 = p[3 * s], r4 = p[4 * s], r5 = p[5 * s], r6 = p[6 * s], r7 = p[7 * s]
            let alpha0 = c * r2, alpha1 = f * r2, alpha2 = c * r6, alpha3 = f * r6
            let beta0 = madd(g, r7, madd(e, r5, madd(b, r1, d * r3)))
            let beta1 = madd(-e, r7, madd(-b, r5, madd(d, r1, -(g * r3))))
            let beta2 = madd(d, r7, madd(g, r5, madd(e, r1, -(b * r3))))
            let beta3 = madd(-b, r7, madd(d, r5, madd(g, r1, -(e * r3))))
            let theta0 = a * (r0 + r4), theta3 = a * (r0 - r4)
            let theta1 = alpha0 + alpha3, theta2 = alpha1 - alpha2
            let gamma0 = theta0 + theta1, gamma1 = theta3 + theta2
            let gamma2 = theta3 - theta2, gamma3 = theta0 - theta1
            p[0] = gamma0 + beta0
            p[s] = gamma1 + beta1
            p[2 * s] = gamma2 + beta2
            p[3 * s] = gamma3 + beta3
            p[4 * s] = gamma3 - beta3
            p[5 * s] = gamma2 - beta2
            p[6 * s] = gamma1 - beta1
            p[7 * s] = gamma0 - beta0
        }
        for row in 0..<8 - zeroedRows { pass(data + row * 8, 1) }
        for column in 0..<8 { pass(data + column, 8) }
    }

    /// csc709Inverse: Y'CbCr to R'G'B' (709 primaries, Cb and Cr centred on 0).
    static func inverseCSC(_ c0: UnsafeMutablePointer<Float>, _ c1: UnsafeMutablePointer<Float>,
                           _ c2: UnsafeMutablePointer<Float>, count: Int) {
        for i in 0..<count {
            let y = c0[i], cb = c1[i], cr = c2[i]
            c0[i] = madd(1.5747, cr, y)
            c1[i] = madd(-0.4682, cr, madd(-0.1873, cb, y))
            c2[i] = madd(1.8556, cb, y)
        }
    }
}

extension EXRImage {
    /// DWA's curve back to linear light, for every half (OpenEXR's dwaCompressorToLinear, computed as its
    /// generator does): x^2.2 up to 1, e^(2.2 (x - 1)) above, odd in x; infinities and NaNs go to 0.
    static let dwaToLinear: [UInt16] = {
        let logBase = Float(pow(2.7182818, 2.2))
        return (0..<65536).map { i -> UInt16 in
            let h = Float(Float16(bitPattern: UInt16(i)))
            guard h.isFinite else { return 0 }
            let sign: Float = h < 0 ? -1 : 1
            let x = abs(h)
            let v = x <= 1 ? sign * powf(x, 2.2) : sign * powf(logBase, x - 1)
            return Float16(v).bitPattern
        }
    }()
}
