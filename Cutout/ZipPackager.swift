import Foundation

/// Minimal pure-Swift ZIP writer. Uses **stored** (method 0) entries — no
/// deflate compression. This is fine for LINE sticker packs because the
/// APNG payloads are already compressed, and it keeps the implementation
/// dependency-free.
enum ZipPackager {

    enum ZipError: LocalizedError {
        case readFailed(URL)
        case writeFailed(String)

        var errorDescription: String? {
            switch self {
            case .readFailed(let url): return "Couldn't read \(url.lastPathComponent)."
            case .writeFailed(let m):  return "Zip write failed: \(m)"
            }
        }
    }

    /// Write `files` as a ZIP archive to `outputURL`. `files` preserves the
    /// caller's ordering; each entry's `name` is used verbatim as the
    /// archive member name (no directory stripping).
    static func write(files: [(name: String, url: URL)], to outputURL: URL) throws {
        var zipData = Data()
        var centralDirectory = Data()
        var entryCount: UInt16 = 0
        var cdOffset: UInt32 = 0

        for (name, fileURL) in files {
            guard let fileData = try? Data(contentsOf: fileURL) else {
                throw ZipError.readFailed(fileURL)
            }
            let nameBytes = Array(name.utf8)
            let crc = Self.crc32(bytes: fileData)
            let lfhOffset = UInt32(zipData.count)

            // Local file header (30 bytes + filename)
            var lfh = Data()
            lfh.append(contentsOf: [0x50, 0x4B, 0x03, 0x04])   // signature
            lfh.append(contentsOf: u16(20))                    // version needed
            lfh.append(contentsOf: u16(0))                     // flags
            lfh.append(contentsOf: u16(0))                     // method: stored
            lfh.append(contentsOf: u16(0))                     // mod time
            lfh.append(contentsOf: u16(0))                     // mod date
            lfh.append(contentsOf: u32(crc))
            lfh.append(contentsOf: u32(UInt32(fileData.count)))  // compressed size
            lfh.append(contentsOf: u32(UInt32(fileData.count)))  // uncompressed size
            lfh.append(contentsOf: u16(UInt16(nameBytes.count)))
            lfh.append(contentsOf: u16(0))                     // extra len
            lfh.append(contentsOf: nameBytes)

            zipData.append(lfh)
            zipData.append(fileData)

            // Central directory entry (46 bytes + filename)
            var cd = Data()
            cd.append(contentsOf: [0x50, 0x4B, 0x01, 0x02])    // signature
            cd.append(contentsOf: u16(20))                     // version made by
            cd.append(contentsOf: u16(20))                     // version needed
            cd.append(contentsOf: u16(0))                      // flags
            cd.append(contentsOf: u16(0))                      // method
            cd.append(contentsOf: u16(0))                      // mod time
            cd.append(contentsOf: u16(0))                      // mod date
            cd.append(contentsOf: u32(crc))
            cd.append(contentsOf: u32(UInt32(fileData.count)))
            cd.append(contentsOf: u32(UInt32(fileData.count)))
            cd.append(contentsOf: u16(UInt16(nameBytes.count)))
            cd.append(contentsOf: u16(0))                      // extra len
            cd.append(contentsOf: u16(0))                      // comment len
            cd.append(contentsOf: u16(0))                      // disk
            cd.append(contentsOf: u16(0))                      // internal attrs
            cd.append(contentsOf: u32(0))                      // external attrs
            cd.append(contentsOf: u32(lfhOffset))
            cd.append(contentsOf: nameBytes)

            centralDirectory.append(cd)
            entryCount += 1
        }

        cdOffset = UInt32(zipData.count)
        zipData.append(centralDirectory)

        // End of central directory (22 bytes)
        var eocd = Data()
        eocd.append(contentsOf: [0x50, 0x4B, 0x05, 0x06])
        eocd.append(contentsOf: u16(0))                        // disk
        eocd.append(contentsOf: u16(0))                        // disk of CD start
        eocd.append(contentsOf: u16(entryCount))
        eocd.append(contentsOf: u16(entryCount))
        eocd.append(contentsOf: u32(UInt32(centralDirectory.count)))
        eocd.append(contentsOf: u32(cdOffset))
        eocd.append(contentsOf: u16(0))                        // comment
        zipData.append(eocd)

        do {
            try zipData.write(to: outputURL)
        } catch {
            throw ZipError.writeFailed(error.localizedDescription)
        }
    }

    // MARK: - Helpers

    private static func u16(_ v: UInt16) -> [UInt8] {
        [UInt8(v & 0xff), UInt8((v >> 8) & 0xff)]
    }

    private static func u32(_ v: UInt32) -> [UInt8] {
        [UInt8(v & 0xff),
         UInt8((v >> 8) & 0xff),
         UInt8((v >> 16) & 0xff),
         UInt8((v >> 24) & 0xff)]
    }

    private static let crcTable: [UInt32] = {
        var t = [UInt32](repeating: 0, count: 256)
        for i in 0..<256 {
            var c = UInt32(i)
            for _ in 0..<8 {
                c = (c & 1) == 1 ? 0xedb88320 ^ (c >> 1) : c >> 1
            }
            t[i] = c
        }
        return t
    }()

    private static func crc32(bytes: Data) -> UInt32 {
        var crc: UInt32 = 0xffffffff
        for b in bytes {
            crc = crcTable[Int((crc ^ UInt32(b)) & 0xff)] ^ (crc >> 8)
        }
        return crc ^ 0xffffffff
    }
}
