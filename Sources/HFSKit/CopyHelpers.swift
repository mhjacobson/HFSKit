import Foundation

func resolvedRawCopyOutDestinationPath(info: HFSFileInfo, hostPath: URL) -> URL {
    var isDirectory: ObjCBool = false
    if FileManager.default.fileExists(atPath: hostPath.path, isDirectory: &isDirectory),
       isDirectory.boolValue
    {
        var hint = info.name.replacingOccurrences(of: "/", with: "-")
        hint = hint.replacingOccurrences(of: " ", with: "_")
        return hostPath.appendingPathComponent(hint, isDirectory: false)
    }
    return hostPath
}

func resolvedCopyInDestinationPath(stat: (String) throws -> HFSFileInfo,
                                   requestedHFSPath: String,
                                   destinationName: String) throws -> String {
    do {
        let destinationInfo = try stat(requestedHFSPath)
        if destinationInfo.isDirectory {
            if requestedHFSPath == ":" {
                return ":\(destinationName)"
            }
            if requestedHFSPath.hasSuffix(":") {
                return requestedHFSPath + destinationName
            }
            return requestedHFSPath + ":" + destinationName
        }
        return requestedHFSPath
    } catch let error as HFSError {
        if case let .operationFailed(_, errno, _, _, _) = error, errno == ENOENT {
            return requestedHFSPath
        }
        throw error
    }
}

func rawCopyInDestinationHint(from hostPath: URL) -> String {
    // Match hfsutils copy-in naming behavior in
    // HFSCore/hfsutils/copyin.c: opensrc() + opendst().
    var hint = String(hostPath.lastPathComponent.prefix(31))
    hint = hint.replacingOccurrences(of: ":", with: "-")
    hint = hint.replacingOccurrences(of: "_", with: " ")
    return hint
}

func textCopyInDestinationHint(from hostPath: URL) -> String {
    let baseName = hostPath.lastPathComponent
    let rawHint: String
    if let txtRange = baseName.range(of: ".txt") {
        rawHint = String(baseName[..<txtRange.lowerBound])
    } else {
        rawHint = baseName
    }
    var hint = String(rawHint.prefix(31))
    hint = hint.replacingOccurrences(of: ":", with: "-")
    hint = hint.replacingOccurrences(of: "_", with: " ")
    return hint.isEmpty ? "Untitled" : hint
}

func resolvedTextCopyOutDestinationPath(info: HFSFileInfo, hfsPath: String, hostPath: URL) -> URL {
    var isDirectory: ObjCBool = false
    if FileManager.default.fileExists(atPath: hostPath.path, isDirectory: &isDirectory),
       isDirectory.boolValue
    {
        var hint = info.name.replacingOccurrences(of: "/", with: "-")
        hint = hint.replacingOccurrences(of: " ", with: "_")
        if !hfsPath.contains(".") {
            hint += ".txt"
        }
        return hostPath.appendingPathComponent(hint, isDirectory: false)
    }
    return hostPath
}

func hostTextDataToHFSTextData(_ data: Data) throws -> Data {
    var bytes = [UInt8](data)
    for i in bytes.indices {
        if bytes[i] == 0x0a {
            bytes[i] = 0x0d
        }
    }
    guard let latin1String = String(data: Data(bytes), encoding: .isoLatin1),
          let macRomanData = latin1String.data(using: .macOSRoman, allowLossyConversion: true) else {
        throw HFSError.invalidArgument("Unable to convert text from host encoding to MacRoman.")
    }
    return macRomanData
}

func hfsTextDataToHostTextData(_ data: Data) throws -> Data {
    var bytes = [UInt8](data)
    for i in bytes.indices {
        if bytes[i] == 0x0d {
            bytes[i] = 0x0a
        }
    }
    guard let macRomanString = String(data: Data(bytes), encoding: .macOSRoman),
          let latin1Data = macRomanString.data(using: .isoLatin1, allowLossyConversion: true) else {
        throw HFSError.invalidArgument("Unable to convert text from MacRoman to host encoding.")
    }
    return latin1Data
}

func readHostResourceFork(hostPath: URL) throws -> Data {
    let resourceForkURL = URL(fileURLWithPath: hostPath.path + "/..namedfork/rsrc")

    do {
        return try Data(contentsOf: resourceForkURL, options: .mappedIfSafe)
    } catch {
        // Return empty data for files without a resource fork.
        let nsError = error as NSError
        if nsError.domain == NSCocoaErrorDomain && nsError.code == NSFileReadNoSuchFileError {
            return Data()
        }
        throw error
    }
}

func readHostTypeCreator(hostPath: URL) throws -> (type: String, creator: String) {
    let attributes = try FileManager.default.attributesOfItem(atPath: hostPath.path)
    guard let typeNumber = hfsCodeNumber(from: attributes[.hfsTypeCode]),
          let creatorNumber = hfsCodeNumber(from: attributes[.hfsCreatorCode]),
          let fileType = fourCCString(from: typeNumber),
          let fileCreator = fourCCString(from: creatorNumber) else {
        return ("????", "UNIX")
    }
    return (fileType, fileCreator)
}

func writeHostResourceFork(data: Data, hostPath: URL) throws {
    let resourceForkURL = URL(fileURLWithPath: hostPath.path + "/..namedfork/rsrc")
    try data.write(to: resourceForkURL, options: [])
}

func writeHostTypeCreator(fileType: String, fileCreator: String, hostPath: URL) throws {
    guard let typeCode = fourCCNumber(from: fileType),
          let creatorCode = fourCCNumber(from: fileCreator) else {
        return
    }
    let attributes: [FileAttributeKey: Any] = [
        .hfsTypeCode: typeCode,
        .hfsCreatorCode: creatorCode
    ]
    try FileManager.default.setAttributes(attributes, ofItemAtPath: hostPath.path)
}

func hfsCodeNumber(from value: Any?) -> UInt32? {
    if let number = value as? NSNumber {
        return number.uint32Value
    }
    if let value = value as? UInt32 {
        return value
    }
    return nil
}

func fourCCString(from value: UInt32) -> String? {
    let bigEndian = value.bigEndian
    let data = withUnsafeBytes(of: bigEndian) { Data($0) }
    guard let string = String(data: data, encoding: .macOSRoman), string.count == 4 else {
        return nil
    }
    return string
}

func fourCCNumber(from string: String) -> NSNumber? {
    guard string.count == 4, let data = string.data(using: .macOSRoman), data.count == 4 else {
        return nil
    }
    let value = data.reduce(UInt32(0)) { partial, byte in
        (partial << 8) | UInt32(byte)
    }
    return NSNumber(value: value)
}
