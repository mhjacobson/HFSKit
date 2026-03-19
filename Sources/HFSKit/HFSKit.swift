// HFSKit.swift
// HFSKit - A Swift wrapper of hfsutils for editing HFS disk images
// Copyright (C) 2026 David Kopec
//
// This program is free software: you can redistribute it and/or modify
// it under the terms of the GNU General Public License as published by
// the Free Software Foundation, either version 3 of the License, or
// (at your option) any later version.
//
// This program is distributed in the hope that it will be useful,
// but WITHOUT ANY WARRANTY; without even the implied warranty of
// MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
// GNU General Public License for more details.
//
// You should have received a copy of the GNU General Public License
// along with this program.  If not, see <https://www.gnu.org/licenses/>.
//
// Usage in SwiftPM:
// - C target "HFSCore" builds hfswrapper.c and links against libhfs.
// - Swift target "HFSKit" depends on "HFSCore" and imports it.
//
// Usage example:
//
//   import HFSKit
//
//   let vol = try HFSVolume(path: URL(fileURLWithPath: "/path/to/image.dsk"),
//                           writable: true)
//   let entries = try vol.list(directory: ":System Folder")
//   try vol.copyIn(hostPath: URL(fileURLWithPath: "/tmp/foo"),
//                  toHFSPath: ":foo")
//   try vol.copyOut(hfsPath: ":System Folder:Finder",
//                   toHostPath: URL(fileURLWithPath: "/tmp/Finder"))
//

import Foundation
import Darwin
import HFSCore   // This is the Clang module for your C target (containing hfswrapper.h/c)

public enum HFSKitSettings {
    public static var verboseLoggingEnabled: Bool {
        get {
            hfsw_get_debug_logging() != 0
        }
        set {
            hfsw_set_debug_logging(newValue ? 1 : 0)
        }
    }
}

public func runHFSCheck(on path: URL) throws -> String {
    var result: Int32 = 1
    var outputPtr: UnsafeMutablePointer<CChar>?

    let error = path.path.withCString { cPath in
        hfsw_hfsck(cPath, &result, &outputPtr)
    }

    if error.code != 0 {
        let detail = error.detail != nil ? String(cString: error.detail) : nil
        throw HFSError.operationFailed(
            operation: "hfsck",
            errno: error.code,
            detail: detail,
            path: path.path,
            destination: nil
        )
    }

    defer {
        if let outputPtr {
            hfsw_free_string(outputPtr)
        }
    }

    let output = outputPtr.map { String(cString: $0) } ?? ""
    if result == 0 {
        return output
    }

    if output.isEmpty {
        return "hfsck reported issues (code \(result))."
    }
    return output
}

// MARK: - Errors

public enum HFSError: Error {
    case openFailed(errno: Int32, detail: String?)
    case operationFailed(operation: String,
                         errno: Int32,
                         detail: String?,
                         path: String?,
                         destination: String?)
    case invalidArgument(String)
    case volumeClosed
    case pathExistsNotDirectory(String)
    case copyInSourceNotDirectory(String)
    case noHFSPPartitions(String)
}

public extension HFSError {
    var userMessage: String {
        switch self {
        case let .openFailed(errno, detail):
            return formatMessage(
                prefix: "Failed to open volume",
                errno: errno,
                detail: detail,
                path: nil,
                destination: nil
            )
        case let .operationFailed(operation, errno, detail, path, destination):
            return formatMessage(
                prefix: "\(operation.capitalized) failed",
                errno: errno,
                detail: detail,
                path: path,
                destination: destination
            )
        case let .invalidArgument(message):
            return message
        case .volumeClosed:
            return "The volume is closed."
        case let .pathExistsNotDirectory(path):
            return "The path exists but is not a directory: \(path)"
        case let .copyInSourceNotDirectory(path):
            return "The source is not a directory: \(path)"
        case let .noHFSPPartitions(path):
            return "No HFS partitions were found in \(path)."
        }
    }
}

extension HFSError: LocalizedError {
    public var errorDescription: String? {
        return userMessage
    }
}

// MARK: - File info

public struct HFSFileInfo: CustomStringConvertible {
    public let name: String
    public let path: String
    public let isDirectory: Bool
    public let dataForkSize: Int
    public let resourceForkSize: Int
    public let fileType: String
    public let fileCreator: String
    public let flags: UInt16
    public let created: Date
    public let modified: Date

    public var description: String {
        return "HFSFileInfo(name: \(name), path: \(path), dir: \(isDirectory), data: \(dataForkSize), rsrc: \(resourceForkSize))"
    }
}

public struct HFSVolumeInfo: CustomStringConvertible {
    public let name: String
    public let flags: UInt32
    public let totalBytes: UInt64
    public let freeBytes: UInt64
    public let allocationBlockSize: UInt32
    public let clumpSize: UInt32
    public let numberOfFiles: UInt32
    public let numberOfDirectories: UInt32
    public let created: Date
    public let modified: Date
    public let backup: Date
    public let blessedFolderId: UInt32

    public var usedBytes: UInt64 {
        return totalBytes - freeBytes
    }

    public var description: String {
        return "HFSVolumeInfo(name: \(name), total: \(totalBytes), free: \(freeBytes))"
    }
}

public struct HFSPartitionInfo: CustomStringConvertible {
    public let index: Int
    public let name: String
    public let type: String
    public let startBlock: UInt32
    public let blockCount: UInt32
    public let dataStart: UInt32
    public let dataCount: UInt32
    public let isHFS: Bool

    public var description: String {
        return "HFSPartitionInfo(index: \(index), name: \(name), type: \(type), hfs: \(isHFS))"
    }
}

// MARK: - Volume

public final class HFSVolume {
    private static let maxVolumeBytes: UInt64 = 2 * 1024 * 1024 * 1024
    private static let maxVolumeNameLength: Int = 27

    private var handle: UnsafeMutablePointer<HFSImage>?

    public var isClosed: Bool {
        return handle == nil
    }

    public init(path: URL, writable: Bool, partition: Int? = nil) throws {
        let cPath = path.path.cString(using: .utf8)!
        let rw = writable ? 1 : 0
        let partno = try HFSVolume.resolvePartitionNumber(
            at: path,
            explicitPartition: partition
        )

        let result = hfsw_open_image_ex(cPath, Int32(rw), Int32(partno))
        guard let h = result.image else {
            let detail = result.error.detail != nil
                ? String(cString: result.error.detail)
                : nil
            throw HFSError.openFailed(errno: result.error.code, detail: detail)
        }
        self.handle = h
    }

    public static func createBlank(path: URL, size: UInt64, volumeName: String) throws {
        if size > maxVolumeBytes {
            throw HFSError.invalidArgument(
                "Volume size \(size) exceeds the maximum supported HFS size of 2 GiB (\(maxVolumeBytes) bytes)."
            )
        }

        if volumeName.count > maxVolumeNameLength {
            throw HFSError.invalidArgument(
                "Volume name \"\(volumeName)\" is \(volumeName.count) characters; HFS allows at most \(maxVolumeNameLength)."
            )
        }

        let error = path.path.withCString { cPath in
            volumeName.withCString { cName in
                hfsw_create_blank_image(cPath, size, cName)
            }
        }

        if error.code != 0 {
            let detail = error.detail != nil ? String(cString: error.detail) : nil
            throw HFSError.operationFailed(
                operation: "create blank volume",
                errno: error.code,
                detail: detail,
                path: path.path,
                destination: nil
            )
        }
    }

    deinit {
        close()
    }

    public func close() {
        if let h = handle {
            hfsw_close_image(h)
            handle = nil
        }
    }

    public static func listPartitions(path: URL) throws -> [HFSPartitionInfo] {
        let context = PartitionListContext()
        let ctxPtr = Unmanaged.passUnretained(context).toOpaque()

        let callback: hfsw_partition_callback = { infoPtr, rawCtx in
            guard let infoPtr = infoPtr,
                  let rawCtx = rawCtx else { return }

            let ctx = Unmanaged<PartitionListContext>
                .fromOpaque(rawCtx)
                .takeUnretainedValue()

            let cInfo = infoPtr.pointee
            let info = HFSPartitionInfo(
                index: Int(cInfo.index),
                name: stringFromFixedArray(cInfo.name),
                type: stringFromFixedArray(cInfo.type),
                startBlock: cInfo.startBlock,
                blockCount: cInfo.blockCount,
                dataStart: cInfo.dataStart,
                dataCount: cInfo.dataCount,
                isHFS: cInfo.isHFS != 0
            )
            ctx.items.append(info)
        }

        var hasMap: Int32 = 0
        let error = path.path.withCString { cPath in
            hfsw_list_partitions(cPath, callback, ctxPtr, &hasMap)
        }
        if error.code != 0 {
            let detail = error.detail != nil ? String(cString: error.detail) : nil
            throw HFSError.operationFailed(
                operation: "list partitions",
                errno: error.code,
                detail: detail,
                path: path.path,
                destination: nil
            )
        }
        context.hasPartitionMap = hasMap != 0
        return context.items
    }

    private func requireHandle() throws -> UnsafeMutablePointer<HFSImage> {
        guard let h = handle else {
            throw HFSError.volumeClosed
        }
        return h
    }

    private final class PartitionListContext {
        var items: [HFSPartitionInfo] = []
        var hasPartitionMap: Bool = false
    }

    private static func resolvePartitionNumber(at path: URL,
                                               explicitPartition: Int?) throws -> Int
    {
        if let explicitPartition {
            return explicitPartition
        }

        let partitions = try listPartitions(path: path)
        if partitions.isEmpty {
            return 0
        }

        if let firstHFS = partitions.first(where: { $0.isHFS }) {
            return firstHFS.index
        }

        throw HFSError.noHFSPPartitions(path.path)
    }

    private func throwIfError(_ error: HFSWError,
                              operation: String,
                              path: String? = nil,
                              destination: String? = nil) throws
    {
        guard error.code != 0 else { return }
        let detail = error.detail != nil
            ? String(cString: error.detail)
            : nil
        throw HFSError.operationFailed(
            operation: operation,
            errno: error.code,
            detail: detail,
            path: path,
            destination: destination
        )
    }

    // MARK: - Stat

    public func stat(path: String) throws -> HFSFileInfo {
        let h = try requireHandle()

        var cInfo = HFSWFileInfo()
        let error = try withHFSPathCString(path) { cPath in
            hfsw_stat(h, cPath, &cInfo)
        }
        try throwIfError(error, operation: "stat", path: path)

        return HFSFileInfo(from: cInfo, path: path)
    }

    public func attributes(of path: String) throws -> HFSFileInfo {
        return try stat(path: path)
    }

    // MARK: - Directory listing

    private final class ListContext {
        var items: [HFSFileInfo] = []
        var basePath: String = ":"
    }

    public func list(directory hfsPath: String = ":") throws -> [HFSFileInfo] {
        let h = try requireHandle()
        let context = ListContext()
        let ctxPtr = Unmanaged.passUnretained(context).toOpaque()

        context.basePath = hfsPath.isEmpty ? ":" : hfsPath
        let callback: hfsw_list_callback = { infoPtr, rawCtx in
            guard let infoPtr = infoPtr,
                  let rawCtx = rawCtx else { return }

            let ctx = Unmanaged<ListContext>
                .fromOpaque(rawCtx)
                .takeUnretainedValue()

            let cInfo = infoPtr.pointee
            let name = stringFromFixedArray(cInfo.name)
            let itemPath = joinHFSPath(ctx.basePath, name)
            let swiftInfo = HFSFileInfo(from: cInfo, path: itemPath)
            ctx.items.append(swiftInfo)
        }

        let status = try withHFSPathCString(context.basePath) { cPath in
            hfsw_list_dir(h, cPath, callback, ctxPtr)
        }

        try throwIfError(status, operation: "list", path: hfsPath)

        return context.items
    }

    // MARK: - Volume info

    public func volumeInfo() throws -> HFSVolumeInfo {
        let h = try requireHandle()

        var cInfo = HFSWVolumeInfo()
        let error = hfsw_volume_info(h, &cInfo)
        try throwIfError(error, operation: "volume info", path: nil)

        return HFSVolumeInfo(from: cInfo)
    }

    // MARK: - Basic operations

    public func delete(path: String) throws {
        let h = try requireHandle()
        let error = try withHFSPathCString(path) { cPath in
            hfsw_delete(h, cPath)
        }
        try throwIfError(error, operation: "delete", path: path)
    }

    public func delete(_ info: HFSFileInfo) throws {
        if info.isDirectory {
            try deleteDirectory(info)
        } else {
            try delete(path: info.path)
        }
    }

    public func rename(path: String, to newName: String) throws {
        let h = try requireHandle()
        let error = try withHFSPathCString(path) { cOld in
            try withHFSPathCString(newName) { cNew in
                hfsw_rename(h, cOld, cNew)
            }
        }
        try throwIfError(error, operation: "rename", path: path, destination: newName)
    }

    public func rename(_ info: HFSFileInfo, to newName: String) throws {
        try rename(path: info.path, to: newName)
    }

    public func move(path: String, toParentDirectory: String) throws {
        let h = try requireHandle()
        let error = try withHFSPathCString(path) { cOld in
            try withHFSPathCString(toParentDirectory) { cParent in
                hfsw_move(h, cOld, cParent)
            }
        }
        try throwIfError(error, operation: "move", path: path, destination: toParentDirectory)
    }

    public func move(_ info: HFSFileInfo, toParentDirectory: String) throws {
        try move(path: info.path, toParentDirectory: toParentDirectory)
    }

    public func makeDirectory(path: String) throws {
        let h = try requireHandle()
        let error = try withHFSPathCString(path) { cPath in
            hfsw_mkdir(h, cPath)
        }
        try throwIfError(error, operation: "mkdir", path: path)
    }

    public func makeDirectory(_ info: HFSFileInfo) throws {
        try makeDirectory(path: info.path)
    }

    // MARK: - Copy in/out

    public enum CopyMode: Int32 {
        case auto = 0
        case raw  = 1
        case macBinary = 2
        case binHex = 3
        case text = 4
    }

    public func copyIn(hostPath: URL,
                       toHFSPath hfsPath: String,
                       mode: CopyMode = .auto) throws
    {
        let h = try requireHandle()

        let error = try hostPath.path.withCString { cHost in
            try withHFSPathCString(hfsPath) { cHFS in
                hfsw_copy_in(h, cHost, cHFS, mode.rawValue)
            }
        }

        try throwIfError(
            error,
            operation: "copy in",
            path: hfsPath,
            destination: hostPath.path
        )
    }

    public func copyIn(hostPath: URL,
                       toHFSPath info: HFSFileInfo,
                       mode: CopyMode = .auto) throws
    {
        try copyIn(hostPath: hostPath, toHFSPath: info.path, mode: mode)
    }

    public func copyOut(hfsPath: String,
                        toHostPath hostPath: URL,
                        mode: CopyMode = .auto) throws
    {
        let h = try requireHandle()

        let error = try withHFSPathCString(hfsPath) { cHFS in
            hostPath.path.withCString { cHost in
                hfsw_copy_out(h, cHFS, cHost, mode.rawValue)
            }
        }

        try throwIfError(
            error,
            operation: "copy out",
            path: hfsPath,
            destination: hostPath.path
        )
    }

    public func copyOut(hfsPath info: HFSFileInfo,
                        toHostPath hostPath: URL,
                        mode: CopyMode = .auto) throws
    {
        if info.isDirectory {
            try copyOutDirectory(hfsPath: info.path, toHostDirectory: hostPath, mode: mode)
        } else {
            try copyOut(hfsPath: info.path, toHostPath: hostPath, mode: mode)
        }
    }

    public func copyInDirectory(hostDirectory: URL,
                                toHFSPath hfsPath: String,
                                mode: CopyMode = .auto) throws
    {
        let fm = FileManager.default
        var isDir: ObjCBool = false
        guard fm.fileExists(atPath: hostDirectory.path, isDirectory: &isDir), isDir.boolValue else {
            throw HFSError.copyInSourceNotDirectory(hostDirectory.path)
        }

        try ensureDirectoryExists(at: hfsPath)

        let baseURL = hostDirectory.resolvingSymlinksInPath()
        let baseComponents = baseURL.pathComponents

        let enumerator = fm.enumerator(at: baseURL, includingPropertiesForKeys: [.isDirectoryKey], options: [])
        while let item = enumerator?.nextObject() as? URL {
            let itemURL = item.resolvingSymlinksInPath()
            let itemComponents = itemURL.pathComponents
            let relComponents = Array(itemComponents.dropFirst(baseComponents.count))
            let destPath = relComponents.reduce(hfsPath) { current, component in
                joinHFSPath(current, component)
            }

            let resourceValues = try item.resourceValues(forKeys: [.isDirectoryKey])
            if resourceValues.isDirectory == true {
                try ensureDirectoryExists(at: destPath)
            } else {
                if recursiveCopyInUsesDirectoryDestination(hostPath: item, mode: mode) {
                    let parentPath = relComponents.dropLast().reduce(hfsPath) { current, component in
                        joinHFSPath(current, component)
                    }
                    try copyIn(hostPath: item, toHFSPath: parentPath, mode: mode)
                } else {
                    try copyIn(hostPath: item, toHFSPath: destPath, mode: mode)
                }
            }
        }
    }

    public func copyOutDirectory(hfsPath: String,
                                 toHostDirectory hostDirectory: URL,
                                 mode: CopyMode = .auto) throws
    {
        let fm = FileManager.default
        try fm.createDirectory(at: hostDirectory, withIntermediateDirectories: true)

        for entry in try list(directory: hfsPath) {
            let entryHFSPath = joinHFSPath(hfsPath, entry.name)
            let safeName = sanitizeHostPathComponent(entry.name)
            let entryHostURL = hostDirectory.appendingPathComponent(safeName)
            if entry.isDirectory {
                try copyOutDirectory(hfsPath: entryHFSPath, toHostDirectory: entryHostURL, mode: mode)
            } else {
                if recursiveCopyOutUsesDirectoryDestination(entry: entry, mode: mode) {
                    try copyOut(hfsPath: entryHFSPath, toHostPath: hostDirectory, mode: mode)
                } else {
                    try copyOut(hfsPath: entryHFSPath, toHostPath: entryHostURL, mode: mode)
                }
            }
        }
    }

    // MARK: - Type/creator

    public func setTypeCreator(path: String,
                               fileType: String,
                               fileCreator: String) throws
    {
        let h = try requireHandle()

        let error = try withHFSPathCString(path) { cPath in
            fileType.withCString { cType in
                fileCreator.withCString { cCreator in
                    hfsw_set_type_creator(h, cPath, cType, cCreator)
                }
            }
        }

        try throwIfError(error, operation: "set type/creator", path: path)
    }

    public func setTypeCreator(path info: HFSFileInfo,
                               fileType: String,
                               fileCreator: String) throws
    {
        try setTypeCreator(path: info.path, fileType: fileType, fileCreator: fileCreator)
    }

    public func setBlessed(path: String) throws {
        let h = try requireHandle()

        let error = try withHFSPathCString(path) { cPath in
            hfsw_set_blessed(h, cPath)
        }

        try throwIfError(error, operation: "set blessed folder", path: path)
    }

    public func setBlessed(_ info: HFSFileInfo) throws {
        try setBlessed(path: info.path)
    }

    // MARK: - Directory delete

    public func deleteDirectory(path: String) throws {
        let info = try stat(path: path)
        if info.isDirectory {
            for entry in try list(directory: path) {
                let entryPath = joinHFSPath(path, entry.name)
                if entry.isDirectory {
                    try deleteDirectory(path: entryPath)
                } else {
                    try delete(path: entryPath)
                }
            }
        }
        try delete(path: path)
    }

    public func deleteDirectory(_ info: HFSFileInfo) throws {
        try deleteDirectory(path: info.path)
    }

    private func ensureDirectoryExists(at hfsPath: String) throws {
        do {
            let info = try stat(path: hfsPath)
            if !info.isDirectory {
                throw HFSError.pathExistsNotDirectory(hfsPath)
            }
        } catch {
            try makeDirectory(path: hfsPath)
        }
    }
}

// MARK: - Internal conversion

private extension HFSFileInfo {
    init(from cInfo: HFSWFileInfo, path: String) {
        let name = stringFromFixedArray(cInfo.name)

        let typeStr = stringFromFixedArray(cInfo.fileType)
        let creatorStr = stringFromFixedArray(cInfo.fileCreator)

        self.init(
            name: name,
            path: path,
            isDirectory: cInfo.isDirectory != 0,
            dataForkSize: Int(cInfo.dataForkSize),
            resourceForkSize: Int(cInfo.rsrcForkSize),
            fileType: typeStr,
            fileCreator: creatorStr,
            flags: cInfo.flags,
            created: Date(timeIntervalSince1970: TimeInterval(cInfo.created)),
            modified: Date(timeIntervalSince1970: TimeInterval(cInfo.modified))
        )
    }
}

private extension HFSVolumeInfo {
    init(from cInfo: HFSWVolumeInfo) {
        self.init(
            name: stringFromFixedArray(cInfo.name),
            flags: cInfo.flags,
            totalBytes: cInfo.totalBytes,
            freeBytes: cInfo.freeBytes,
            allocationBlockSize: cInfo.allocationBlockSize,
            clumpSize: cInfo.clumpSize,
            numberOfFiles: cInfo.numberOfFiles,
            numberOfDirectories: cInfo.numberOfDirectories,
            created: Date(timeIntervalSince1970: TimeInterval(cInfo.created)),
            modified: Date(timeIntervalSince1970: TimeInterval(cInfo.modified)),
            backup: Date(timeIntervalSince1970: TimeInterval(cInfo.backup)),
            blessedFolderId: cInfo.blessedFolderId
        )
    }
}

private func stringFromFixedArray<T>(_ array: T) -> String {
    return withUnsafeBytes(of: array) { raw in
        let bytes = raw.bindMemory(to: UInt8.self)
        let end = bytes.firstIndex(of: 0) ?? bytes.count
        let data = Data(bytes[..<end])
        return String(data: data, encoding: .macOSRoman)
            ?? String(data: data, encoding: .utf8)
            ?? String(decoding: bytes[..<end], as: UTF8.self)
    }
}

private func withHFSPathCString<R>(_ hfsPath: String,
                                   _ body: (UnsafePointer<CChar>) throws -> R) throws -> R
{
    guard let data = hfsPath.data(using: .macOSRoman, allowLossyConversion: false) else {
        throw HFSError.invalidArgument(
            "HFS path contains characters not representable in MacRoman: \(hfsPath)"
        )
    }

    var bytes = [UInt8](data)
    bytes.append(0)
    return try bytes.withUnsafeBufferPointer { buffer in
        guard let base = buffer.baseAddress else {
            throw HFSError.invalidArgument("Empty HFS path buffer")
        }
        return try body(UnsafeRawPointer(base).assumingMemoryBound(to: CChar.self))
    }
}

private func joinHFSPath(_ base: String, _ name: String) -> String {
    if base == ":" { return ":\(name)" }
    if base.hasSuffix(":") { return base + name }
    return base + ":\(name)"
}

private func sanitizeHostPathComponent(_ name: String) -> String {
    if name.contains("/") {
        return name.replacingOccurrences(of: "/", with: "-")
    }
    return name
}

private func recursiveCopyOutUsesDirectoryDestination(entry: HFSFileInfo,
                                                      mode: HFSVolume.CopyMode) -> Bool
{
    switch mode {
    case .auto:
        return entry.resourceForkSize > 0
    case .macBinary, .binHex:
        return true
    case .raw, .text:
        return false
    }
}

private func recursiveCopyInUsesDirectoryDestination(hostPath: URL,
                                                     mode: HFSVolume.CopyMode) -> Bool
{
    switch mode {
    case .auto:
        let lowercasedName = hostPath.lastPathComponent.lowercased()
        return lowercasedName.hasSuffix(".bin") || lowercasedName.hasSuffix(".hqx")
    case .macBinary, .binHex:
        return true
    case .raw, .text:
        return false
    }
}

private func formatMessage(prefix: String,
                           errno: Int32,
                           detail: String?,
                           path: String?,
                           destination: String?) -> String
{
    var parts: [String] = [prefix]
    if let path {
        parts.append(path)
    }
    if let destination {
        parts.append("->")
        parts.append(destination)
    }
    let posixMessage = errno == 0 ? nil : String(cString: strerror(errno))
    if let posixMessage, !posixMessage.isEmpty {
        parts.append("-")
        parts.append(posixMessage)
    }
    if let detail, !detail.isEmpty {
        parts.append("-")
        parts.append(detail)
    }
    return parts.joined(separator: " ")
}
