import Foundation

struct MacBinary {
    struct File {
        let name: String
        let fileType: String
        let fileCreator: String
        let finderFlags: UInt16
        let created: Date
        let modified: Date
        let dataFork: Data
        let resourceFork: Data
    }

    private static let blockSize = 128
    private static let typeOffset = 65
    private static let creatorOffset = 69
    private static let dataForkLengthOffset = 83
    private static let resourceForkLengthOffset = 87
    private static let crcOffset = 124
    private static let timediff: Int64 = 2_082_844_800
    private static let finderImportFlagsMask = UInt16((1 << 0) | (1 << 8) | (1 << 9))

    static func resolvedCopyOutDestinationPath(info: HFSFileInfo, hostURL: URL) -> URL {
        var isDirectory: ObjCBool = false
        if FileManager.default.fileExists(atPath: hostURL.path, isDirectory: &isDirectory),
           isDirectory.boolValue
        {
            let hint = hostNameHint(from: info.name)
            return hostURL.appendingPathComponent(hint + ".bin", isDirectory: false)
        }
        return hostURL
    }

    static func encode(info: HFSFileInfo, dataFork: Data, resourceFork: Data) throws -> Data {
        var header = Data(repeating: 0, count: blockSize)

        let nameData = try nameData(for: info.name)
        header[1] = UInt8(nameData.count)
        header.replaceSubrange(2..<(2 + nameData.count), with: nameData)

        let typeData = fourCCData(from: info.fileType)
        let creatorData = fourCCData(from: info.fileCreator)
        header.replaceSubrange(typeOffset..<(typeOffset + 4), with: typeData)
        header.replaceSubrange(creatorOffset..<(creatorOffset + 4), with: creatorData)

        header[73] = UInt8((info.flags >> 8) & 0xff)
        header[101] = UInt8(info.flags & 0xff)
        header[122] = 129
        header[123] = 129

        putBE32(UInt32(dataFork.count), in: &header, at: dataForkLengthOffset)
        putBE32(UInt32(resourceFork.count), in: &header, at: resourceForkLengthOffset)
        putBE32(macTime(for: info.created), in: &header, at: 91)
        putBE32(macTime(for: info.modified), in: &header, at: 95)

        let crc = macBinaryCRC(header.prefix(crcOffset))
        putBE16(crc, in: &header, at: crcOffset)

        var encoded = Data()
        encoded.append(header)
        encoded.append(dataFork)
        appendPadding(to: &encoded, dataLength: dataFork.count)
        encoded.append(resourceFork)
        appendPadding(to: &encoded, dataLength: resourceFork.count)
        return encoded
    }

    static func decode(_ encoded: Data) throws -> File {
        guard encoded.count >= blockSize else {
            throw HFSError.invalidArgument("Invalid MacBinary file header.")
        }

        let header = encoded.prefix(blockSize)
        if header[0] != 0 || header[74] != 0 {
            throw HFSError.invalidArgument("Invalid MacBinary file header.")
        }

        let expectedCRC = getBE16(header, at: crcOffset)
        let actualCRC = macBinaryCRC(header.prefix(crcOffset))
        if expectedCRC != actualCRC {
            throw HFSError.invalidArgument("Unknown, unsupported, or corrupt MacBinary file.")
        }

        if header[123] > 129 {
            throw HFSError.invalidArgument("Unsupported MacBinary file version.")
        }

        let nameLength = Int(header[1])
        guard nameLength >= 1, nameLength <= 63, header[2 + nameLength] == 0 else {
            throw HFSError.invalidArgument("Invalid MacBinary file header (bad file name).")
        }

        let rawName = Data(header[2..<(2 + nameLength)])
        guard let name = String(data: rawName, encoding: .macOSRoman), !name.contains(":") else {
            throw HFSError.invalidArgument("Invalid MacBinary file header (bad file name).")
        }

        let dataLength = Int(getBE32(header, at: dataForkLengthOffset))
        let resourceLength = Int(getBE32(header, at: resourceForkLengthOffset))
        guard dataLength >= 0, resourceLength >= 0 else {
            throw HFSError.invalidArgument("Invalid MacBinary file header (bad file length).")
        }

        let dataForkStart = blockSize
        let dataForkEnd = dataForkStart + dataLength
        let dataForkPad = paddedLength(dataLength) - dataLength
        let resourceStart = dataForkEnd + dataForkPad
        let resourceEnd = resourceStart + resourceLength
        guard resourceEnd <= encoded.count else {
            throw HFSError.invalidArgument("Invalid MacBinary file header (bad file length).")
        }

        let fileType = decodeFourCC(header, at: typeOffset)
        let fileCreator = decodeFourCC(header, at: creatorOffset)
        let rawFinderFlags = (UInt16(header[73]) << 8) | UInt16(header[101])
        let finderFlags = rawFinderFlags & ~finderImportFlagsMask
        let created = localDate(fromMacTime: getBE32(header, at: 91))
        let modified = localDate(fromMacTime: getBE32(header, at: 95))
        let dataFork = Data(encoded[dataForkStart..<dataForkEnd])
        let resourceFork = Data(encoded[resourceStart..<resourceEnd])

        return File(name: name,
                    fileType: fileType,
                    fileCreator: fileCreator,
                    finderFlags: finderFlags,
                    created: created,
                    modified: modified,
                    dataFork: dataFork,
                    resourceFork: resourceFork)
    }

    private static func nameData(for name: String) throws -> Data {
        guard let data = name.data(using: .macOSRoman), !data.isEmpty, data.count <= 63 else {
            throw HFSError.invalidArgument("Cannot encode MacBinary filename: \(name)")
        }
        return data
    }

    private static func hostNameHint(from sourceName: String) -> String {
        var hint = sourceName.replacingOccurrences(of: "/", with: "-")
        hint = hint.replacingOccurrences(of: " ", with: "_")
        return hint
    }

    private static func fourCCData(from value: String) -> Data {
        var text = value
        if text.count < 4 {
            text += String(repeating: " ", count: 4 - text.count)
        } else if text.count > 4 {
            text = String(text.prefix(4))
        }
        if let data = text.data(using: .macOSRoman), data.count == 4 {
            return data
        }
        return Data("????".utf8.prefix(4))
    }

    private static func decodeFourCC(_ bytes: Data.SubSequence, at offset: Int) -> String {
        let range = offset..<(offset + 4)
        let data = Data(bytes[range])
        return String(data: data, encoding: .macOSRoman) ?? "????"
    }

    private static func macBinaryCRC(_ bytes: Data.SubSequence) -> UInt16 {
        var crc: UInt16 = 0
        for byte in bytes {
            crc ^= UInt16(byte) << 8
            for _ in 0..<8 {
                if (crc & 0x8000) != 0 {
                    crc = (crc << 1) ^ 0x1021
                } else {
                    crc <<= 1
                }
            }
        }
        return crc
    }

    private static func paddedLength(_ length: Int) -> Int {
        let remainder = length % blockSize
        if remainder == 0 { return length }
        return length + (blockSize - remainder)
    }

    private static func appendPadding(to data: inout Data, dataLength: Int) {
        let padded = paddedLength(dataLength)
        if padded > dataLength {
            data.append(Data(repeating: 0, count: padded - dataLength))
        }
    }

    private static func getBE16(_ data: Data.SubSequence, at offset: Int) -> UInt16 {
        let b0 = UInt16(data[offset])
        let b1 = UInt16(data[offset + 1])
        return (b0 << 8) | b1
    }

    private static func getBE32(_ data: Data.SubSequence, at offset: Int) -> UInt32 {
        let b0 = UInt32(data[offset])
        let b1 = UInt32(data[offset + 1])
        let b2 = UInt32(data[offset + 2])
        let b3 = UInt32(data[offset + 3])
        return (b0 << 24) | (b1 << 16) | (b2 << 8) | b3
    }

    private static func putBE16(_ value: UInt16, in data: inout Data, at offset: Int) {
        data[offset] = UInt8((value >> 8) & 0xff)
        data[offset + 1] = UInt8(value & 0xff)
    }

    private static func putBE32(_ value: UInt32, in data: inout Data, at offset: Int) {
        data[offset] = UInt8((value >> 24) & 0xff)
        data[offset + 1] = UInt8((value >> 16) & 0xff)
        data[offset + 2] = UInt8((value >> 8) & 0xff)
        data[offset + 3] = UInt8(value & 0xff)
    }

    private static func macTime(for date: Date) -> UInt32 {
        let unixTime = Int64(date.timeIntervalSince1970)
        let timeZoneOffset = Int64(TimeZone.current.secondsFromGMT(for: date))
        let value = unixTime + timeZoneOffset + timediff
        if value < 0 { return 0 }
        if value > Int64(UInt32.max) { return UInt32.max }
        return UInt32(value)
    }

    private static func localDate(fromMacTime value: UInt32) -> Date {
        let timeZoneOffset = Int64(TimeZone.current.secondsFromGMT(for: Date()))
        let unixTime = Int64(value) - timediff - timeZoneOffset
        return Date(timeIntervalSince1970: TimeInterval(unixTime))
    }
}
