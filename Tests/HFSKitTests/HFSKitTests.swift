// HFSKitTests.swift
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

import Foundation
import Testing
import HFSCore
@testable import HFSKit

@Test func copyOutSampleFile() async throws {
    HFSKitSettings.verboseLoggingEnabled = false
    let imgURL = try testImageURL()
    let volume = try HFSVolume(path: imgURL, writable: false)
    let tempDir = try makeTempDir()

    let attributes = try volume.attributes(of: ":Sample")
    #expect(attributes.name == "Sample")
    #expect(attributes.path == ":Sample")
    #expect(attributes.isDirectory == false)
    #expect(attributes.fileType == "????")
    #expect(attributes.fileCreator == "UNIX")
    let utcCalendar = Calendar(identifier: .gregorian)
    let expectedComponents = DateComponents(
        timeZone: TimeZone(secondsFromGMT: 0),
        year: 2026,
        month: 1,
        day: 31,
        hour: 4,
        minute: 25,
        second: 57
    )
    let expectedCreated = try #require(utcCalendar.date(from: expectedComponents))
    let fields: Set<Calendar.Component> = [.year, .month, .day, .hour, .minute, .second]
    #expect(utcCalendar.dateComponents(fields, from: attributes.created) == utcCalendar.dateComponents(fields, from: expectedCreated))
    #expect(utcCalendar.dateComponents(fields, from: attributes.modified) == utcCalendar.dateComponents(fields, from: expectedCreated))

    let outputURL = tempDir.appendingPathComponent("Sample")
    let copyOutPaths = ["Sample", ":Sample"]
    var lastError: Error?
    for path in copyOutPaths {
        do {
            try volume.copyOut(hfsPath: path, toHostPath: outputURL)
            lastError = nil
            break
        } catch {
            lastError = error
        }
    }
    if let lastError {
        throw lastError
    }

    let data = try Data(contentsOf: outputURL)
    let text = String(data: data, encoding: .utf8)
    #expect(text?.trimmingCharacters(in: .whitespacesAndNewlines) == "Hello World!")
    #expect(attributes.dataForkSize == data.count)
}

@Test func copyInMountainFile() async throws {
    HFSKitSettings.verboseLoggingEnabled = false
    let mountainURL = try mountainURL()
    let volume = try makeWritableVolume()
    try volume.copyIn(hostPath: mountainURL, toHFSPath: "mountain")

    let attributes = try volume.attributes(of: "mountain")
    #expect(attributes.name == "mountain")
    #expect(attributes.isDirectory == false)
    #expect(attributes.fileType == "????")
    #expect(attributes.fileCreator == "UNIX")
    #expect(attributes.created.timeIntervalSince1970 > 0)
    #expect(attributes.modified.timeIntervalSince1970 >= attributes.created.timeIntervalSince1970)

    let hostData = try Data(contentsOf: mountainURL)
    #expect(attributes.dataForkSize == hostData.count)
    #expect(attributes.resourceForkSize == 0)
}

@Test func createBlankVolumeAndOpen() async throws {
    HFSKitSettings.verboseLoggingEnabled = false
    let tempDir = try makeTempDir()
    let imageURL = tempDir.appendingPathComponent("blank.hda")

    try HFSVolume.createBlank(path: imageURL, size: 8 * 1024 * 1024, volumeName: "BlankVol")

    let volume = try HFSVolume(path: imageURL, writable: false)
    let info = try volume.volumeInfo()
    #expect(info.name == "BlankVol")

    let root = try volume.list(directory: ":")
    #expect(root.isEmpty)
}

@Test func createBlankVolumeCopyRoundTrip() async throws {
    HFSKitSettings.verboseLoggingEnabled = false
    let tempDir = try makeTempDir()
    let imageURL = tempDir.appendingPathComponent("blank-roundtrip.hda")
    let outURL = tempDir.appendingPathComponent("mountain.out")
    let sourceURL = try mountainURL()
    let sourceData = try Data(contentsOf: sourceURL)

    try HFSVolume.createBlank(path: imageURL, size: 8 * 1024 * 1024, volumeName: "BlankRT")

    let volume = try HFSVolume(path: imageURL, writable: true)
    try volume.copyIn(hostPath: sourceURL, toHFSPath: "mountain", mode: .raw)
    try volume.copyOut(hfsPath: "mountain", toHostPath: outURL, mode: .raw)

    let outData = try Data(contentsOf: outURL)
    #expect(outData == sourceData)
}

@Test func setBlessedFolderUpdatesVolumeInfo() async throws {
    HFSKitSettings.verboseLoggingEnabled = false
    let tempDir = try makeTempDir()
    let imageURL = tempDir.appendingPathComponent("blank-blessed.hda")

    try HFSVolume.createBlank(path: imageURL, size: 8 * 1024 * 1024, volumeName: "BlessedVol")
    let volume = try HFSVolume(path: imageURL, writable: true)
    try volume.makeDirectory(path: ":System Folder")
    try volume.setBlessed(path: ":System Folder")

    let info = try volume.volumeInfo()
    #expect(info.blessedFolderId != 0)
}

@Test func setBlessedFailsForFilePath() async throws {
    HFSKitSettings.verboseLoggingEnabled = false
    let volume = try makeWritableVolume()
    let mountainURL = try mountainURL()
    try volume.copyIn(hostPath: mountainURL, toHFSPath: "mountain", mode: .raw)

    do {
        try volume.setBlessed(path: "mountain")
        #expect(Bool(false))
    } catch let error as HFSError {
        guard case let .operationFailed(operation, errno, _, path, _) = error else {
            throw error
        }
        #expect(operation == "set blessed folder")
        #expect(errno == ENOTDIR)
        #expect(path == "mountain")
    }
}

@Test func createBlankRejectsVolumeLargerThan2GiB() async throws {
    HFSKitSettings.verboseLoggingEnabled = false
    let tempDir = try makeTempDir()
    let imageURL = tempDir.appendingPathComponent("too-large.hda")

    do {
        try HFSVolume.createBlank(
            path: imageURL,
            size: (2 * 1024 * 1024 * 1024) + 1,
            volumeName: "TooLarge"
        )
        #expect(Bool(false))
    } catch let error as HFSError {
        guard case let .invalidArgument(message) = error else {
            throw error
        }
        #expect(message.contains("2 GiB"))
    }
}

@Test func createBlankRejectsVolumeNameLongerThan27Characters() async throws {
    HFSKitSettings.verboseLoggingEnabled = false
    let tempDir = try makeTempDir()
    let imageURL = tempDir.appendingPathComponent("bad-name.hda")
    let longName = "1234567890123456789012345678"

    do {
        try HFSVolume.createBlank(path: imageURL, size: 8 * 1024 * 1024, volumeName: longName)
        #expect(Bool(false))
    } catch let error as HFSError {
        guard case let .invalidArgument(message) = error else {
            throw error
        }
        #expect(message.contains("at most 27"))
    }
}

@Test func runHFSCheckReturnsTextOutput() async throws {
    HFSKitSettings.verboseLoggingEnabled = false
    let imgURL = try testImageURL()
    let tempDir = try makeTempDir()
    let writableImageURL = tempDir.appendingPathComponent("check.img")
    try FileManager.default.copyItem(at: imgURL, to: writableImageURL)

    let output = try runHFSCheck(on: writableImageURL)
    #expect(!output.isEmpty)
    #expect(output.contains("*** Checking"))
}

@Test func runMDBFix() async throws {
    HFSKitSettings.verboseLoggingEnabled = false
    let imgURL = try testImageURL()
    let tempDir = try makeTempDir()
    let brokenURL = tempDir.appendingPathComponent("broken-mdb.img")
    try FileManager.default.copyItem(at: imgURL, to: brokenURL)

    let handle = try FileHandle(forUpdating: brokenURL)
    defer { try? handle.close() }

    /* MDB is at logical block 2; signature is first 2 bytes of MDB. */
    try handle.seek(toOffset: 2 * 512)
    try handle.write(contentsOf: Data([0x00, 0x00]))

    let output = try runHFSCheck(on: brokenURL)
    #expect(output.contains("Bad volume signature"))

    let repaired = try HFSVolume(path: brokenURL, writable: false)
    let info = try repaired.volumeInfo()
    #expect(!info.name.isEmpty)
}

@Test func listAndDeleteMountainFile() async throws {
    HFSKitSettings.verboseLoggingEnabled = false
    let mountainURL = try mountainURL()
    let volume = try makeWritableVolume()
    let infoBefore = try volume.volumeInfo()
    try volume.copyIn(hostPath: mountainURL, toHFSPath: "mountain")

    let entriesAfterAdd = try volume.list(directory: ":")
    let mountainEntry = entriesAfterAdd.first { $0.name == "mountain" }
    #expect(mountainEntry != nil)
    #expect(mountainEntry?.isDirectory == false)
    #expect(mountainEntry?.path == ":mountain")
    let hostData = try Data(contentsOf: mountainURL)
    #expect(mountainEntry?.dataForkSize == hostData.count)
    #expect(mountainEntry?.fileType == "????")
    #expect(mountainEntry?.fileCreator == "UNIX")
    let infoAfterAdd = try volume.volumeInfo()
    #expect(infoAfterAdd.usedBytes > infoBefore.usedBytes)

    if let info = try volume.list(directory: ":").first(where: { $0.name == "mountain" }) {
        try volume.delete(info)
    } else {
        throw HFSError.invalidArgument("Expected mountain in root listing")
    }

    let entriesAfterDelete = try volume.list(directory: ":")
    #expect(!entriesAfterDelete.contains { $0.name == "mountain" })
    let infoAfterDelete = try volume.volumeInfo()
    #expect(infoAfterDelete.usedBytes <= infoAfterAdd.usedBytes)
    #expect(infoAfterDelete.usedBytes >= infoBefore.usedBytes)
}

@Test func copyInOutMountainRoundTrip() async throws {
    HFSKitSettings.verboseLoggingEnabled = false
    let mountainURL = try mountainURL()
    let volume = try makeWritableVolume()
    let tempDir = try makeTempDir()

    try volume.copyIn(hostPath: mountainURL, toHFSPath: "mountain")

    let outputURL = tempDir.appendingPathComponent("mountain.out")
    let fileInfo = try volume.attributes(of: "mountain")
    try volume.copyOut(hfsPath: fileInfo, toHostPath: outputURL)

    let inputData = try Data(contentsOf: mountainURL)
    let outputData = try Data(contentsOf: outputURL)
    #expect(outputData == inputData)
}

@Test func renameMountainFile() async throws {
    HFSKitSettings.verboseLoggingEnabled = false
    let mountainURL = try mountainURL()
    let volume = try makeWritableVolume()

    try volume.copyIn(hostPath: mountainURL, toHFSPath: "mountain")
    try volume.rename(path: "mountain", to: "mountain2")

    let entries = try volume.list(directory: ":")
    #expect(entries.contains { $0.name == "mountain2" })
    #expect(!entries.contains { $0.name == "mountain" })
}

@Test func renameNestedFileStaysInParentDirectory() async throws {
    HFSKitSettings.verboseLoggingEnabled = false
    let volume = try makeWritableVolume()
    let mountainURL = try mountainURL()

    try volume.makeDirectory(path: ":Folder")
    try volume.copyIn(hostPath: mountainURL, toHFSPath: ":Folder:mountain")
    try volume.rename(path: ":Folder:mountain", to: "renamed")

    _ = try volume.attributes(of: ":Folder:renamed")
    expectThrows {
        _ = try volume.attributes(of: ":renamed")
    }
}

@Test func renameNestedFolderStaysInParentDirectory() async throws {
    HFSKitSettings.verboseLoggingEnabled = false
    let volume = try makeWritableVolume()

    try volume.makeDirectory(path: ":Parent")
    try volume.makeDirectory(path: ":Parent:Child")
    try volume.rename(path: ":Parent:Child", to: "RenamedChild")

    _ = try volume.attributes(of: ":Parent:RenamedChild")
    expectThrows {
        _ = try volume.attributes(of: ":RenamedChild")
    }
}

@Test func moveFileToDirectory() async throws {
    HFSKitSettings.verboseLoggingEnabled = false
    let mountainURL = try mountainURL()
    let volume = try makeWritableVolume()

    try volume.copyIn(hostPath: mountainURL, toHFSPath: "mountain")
    try volume.makeDirectory(path: ":Folder")
    try volume.move(path: "mountain", toParentDirectory: ":Folder")

    let rootEntries = try volume.list(directory: ":")
    #expect(!rootEntries.contains { $0.name == "mountain" })

    let folderEntries = try volume.list(directory: ":Folder")
    #expect(folderEntries.contains { $0.name == "mountain" && !$0.isDirectory })
}

@Test func moveDirectoryToDirectory() async throws {
    HFSKitSettings.verboseLoggingEnabled = false
    let mountainURL = try mountainURL()
    let volume = try makeWritableVolume()

    try volume.makeDirectory(path: ":FolderA")
    try volume.makeDirectory(path: ":FolderB")
    try volume.copyIn(hostPath: mountainURL, toHFSPath: ":FolderA:mountain")

    let folderInfo = try volume.attributes(of: ":FolderA")
    try volume.move(folderInfo, toParentDirectory: ":FolderB")

    let rootEntries = try volume.list(directory: ":")
    #expect(!rootEntries.contains { $0.name == "FolderA" })

    let folderBEntries = try volume.list(directory: ":FolderB")
    #expect(folderBEntries.contains { $0.name == "FolderA" && $0.isDirectory })

    let movedEntries = try volume.list(directory: ":FolderB:FolderA")
    #expect(movedEntries.contains { $0.name == "mountain" && !$0.isDirectory })
}

@Test func nestedPathOperations() async throws {
    HFSKitSettings.verboseLoggingEnabled = false
    let mountainURL = try mountainURL()
    let volume = try makeWritableVolume()

    try volume.makeDirectory(path: ":Folder")
    try volume.copyIn(hostPath: mountainURL, toHFSPath: ":Folder:mountain")

    let rootEntries = try volume.list(directory: ":")
    #expect(rootEntries.contains { $0.name == "Folder" && $0.isDirectory })

    let folderEntries = try volume.list(directory: ":Folder")
    #expect(folderEntries.contains { $0.name == "mountain" && !$0.isDirectory })

    let fileInfo = try volume.attributes(of: ":Folder:mountain")
    #expect(fileInfo.name == "mountain")
}

@Test func relativeAndAbsolutePathsMatch() async throws {
    HFSKitSettings.verboseLoggingEnabled = false
    let mountainURL = try mountainURL()
    let volume = try makeWritableVolume()

    try volume.copyIn(hostPath: mountainURL, toHFSPath: "mountain")

    let absInfo = try volume.attributes(of: ":mountain")
    let relInfo = try volume.attributes(of: "mountain")
    #expect(absInfo.dataForkSize == relInfo.dataForkSize)
    #expect(absInfo.fileType == relInfo.fileType)
    #expect(absInfo.fileCreator == relInfo.fileCreator)
}

@Test func setTypeCreatorUpdatesAttributes() async throws {
    HFSKitSettings.verboseLoggingEnabled = false
    let mountainURL = try mountainURL()
    let volume = try makeWritableVolume()

    try volume.copyIn(hostPath: mountainURL, toHFSPath: "mountain")
    try volume.setTypeCreator(path: "mountain", fileType: "TEXT", fileCreator: "ttxt")

    let info = try volume.attributes(of: "mountain")
    #expect(info.fileType == "TEXT")
    #expect(info.fileCreator == "ttxt")
}

@Test func errorCases() async throws {
    HFSKitSettings.verboseLoggingEnabled = false
    let imgURL = try testImageURL()
    let mountainURL = try mountainURL()

    let readOnly = try HFSVolume(path: imgURL, writable: false)
    expectThrows {
        try readOnly.copyIn(hostPath: mountainURL, toHFSPath: "mountain")
    }
    expectThrows {
        try readOnly.delete(path: ":Sample")
    }

    expectThrows {
        _ = try readOnly.attributes(of: ":DoesNotExist")
    }
    let tempDir = try makeTempDir()
    let outputURL = tempDir.appendingPathComponent("missing.out")
    expectThrows {
        try readOnly.copyOut(hfsPath: ":DoesNotExist", toHostPath: outputURL)
    }
}

@Test func deleteDirectoryWithContentsFails() async throws {
    HFSKitSettings.verboseLoggingEnabled = false
    let mountainURL = try mountainURL()
    let volume = try makeWritableVolume()

    try volume.makeDirectory(path: ":Folder")
    try volume.copyIn(hostPath: mountainURL, toHFSPath: ":Folder:mountain")

    expectThrows {
        try volume.delete(path: ":Folder")
    }
}

@Test func copyInOutDirectoryAndDeleteRecursively() async throws {
    HFSKitSettings.verboseLoggingEnabled = false
    let volume = try makeWritableVolume()
    let tempDir = try makeTempDir()
    let sourceDir = tempDir.appendingPathComponent("SourceDir", isDirectory: true)
    let outputDir = tempDir.appendingPathComponent("OutputDir", isDirectory: true)

    let (rootFileURL, nestedFileURL) = try createHostDirectoryFixture(at: sourceDir)

    try volume.copyInDirectory(hostDirectory: sourceDir, toHFSPath: ":DirFixture")

    let rootEntries = try volume.list(directory: ":")
    #expect(rootEntries.contains { $0.name == "DirFixture" && $0.isDirectory })
    let fixtureEntries = try volume.list(directory: ":DirFixture")
    #expect(fixtureEntries.contains { $0.name == rootFileURL.lastPathComponent && !$0.isDirectory })
    #expect(fixtureEntries.contains { $0.name == "Sub" && $0.isDirectory })

    let nestedEntries = try volume.list(directory: ":DirFixture:Sub")
    #expect(nestedEntries.contains { $0.name == nestedFileURL.lastPathComponent && !$0.isDirectory })

    let fixtureInfo = try volume.attributes(of: ":DirFixture")
    try volume.copyOut(hfsPath: fixtureInfo, toHostPath: outputDir)

    let copiedRoot = outputDir.appendingPathComponent(rootFileURL.lastPathComponent)
    let copiedNested = outputDir
        .appendingPathComponent("Sub", isDirectory: true)
        .appendingPathComponent(nestedFileURL.lastPathComponent)
    #expect(try Data(contentsOf: copiedRoot) == Data(contentsOf: rootFileURL))
    #expect(try Data(contentsOf: copiedNested) == Data(contentsOf: nestedFileURL))

    try volume.deleteDirectory(fixtureInfo)
    let entriesAfterDelete = try volume.list(directory: ":")
    #expect(!entriesAfterDelete.contains { $0.name == "DirFixture" })
}

@Test func copyInOutDirectoryWithEmptyAndSpacedNames() async throws {
    HFSKitSettings.verboseLoggingEnabled = false
    let volume = try makeWritableVolume()
    let tempDir = try makeTempDir()
    let sourceDir = tempDir.appendingPathComponent("SourceComplex", isDirectory: true)
    let outputDir = tempDir.appendingPathComponent("OutputComplex", isDirectory: true)

    let (rootFileURL, nestedFileURL, emptyDirURL) = try createComplexHostDirectoryFixture(at: sourceDir)
    try volume.copyInDirectory(hostDirectory: sourceDir, toHFSPath: ":DirComplex")

    let complexEntries = try volume.list(directory: ":DirComplex")
    #expect(complexEntries.contains { $0.name == rootFileURL.lastPathComponent })
    #expect(complexEntries.contains { $0.name == emptyDirURL.lastPathComponent && $0.isDirectory })

    try volume.copyOutDirectory(hfsPath: ":DirComplex", toHostDirectory: outputDir)

    let copiedRoot = outputDir.appendingPathComponent(rootFileURL.lastPathComponent)
    let copiedNested = outputDir
        .appendingPathComponent("Sub", isDirectory: true)
        .appendingPathComponent(nestedFileURL.lastPathComponent)
    let copiedEmptyDir = outputDir.appendingPathComponent(emptyDirURL.lastPathComponent, isDirectory: true)

    #expect(try Data(contentsOf: copiedRoot) == Data(contentsOf: rootFileURL))
    #expect(try Data(contentsOf: copiedNested) == Data(contentsOf: nestedFileURL))
    var isDir: ObjCBool = false
    #expect(FileManager.default.fileExists(atPath: copiedEmptyDir.path, isDirectory: &isDir) && isDir.boolValue)
}

@Test func copyOutDirectorySanitizesSlashInNames() async throws {
    HFSKitSettings.verboseLoggingEnabled = false
    let volume = try makeWritableVolume()
    let mountainURL = try mountainURL()
    let tempDir = try makeTempDir()
    let outputDir = tempDir.appendingPathComponent("SlashOutput", isDirectory: true)

    try volume.makeDirectory(path: ":SlashTest")
    try volume.copyIn(hostPath: mountainURL, toHFSPath: ":SlashTest:mountain")
    try volume.rename(path: ":SlashTest:mountain", to: "a/b")

    try volume.copyOutDirectory(hfsPath: ":SlashTest", toHostDirectory: outputDir, mode: .raw)

    let sanitized = outputDir.appendingPathComponent("a-b")
    #expect(FileManager.default.fileExists(atPath: sanitized.path))
    #expect(!FileManager.default.fileExists(atPath: outputDir.appendingPathComponent("a", isDirectory: true).path))
}

@Test func overwriteFileReplacesContents() async throws {
    HFSKitSettings.verboseLoggingEnabled = false
    let volume = try makeWritableVolume()
    let tempDir = try makeTempDir()
    let firstURL = tempDir.appendingPathComponent("first.txt")
    let secondURL = tempDir.appendingPathComponent("second.txt")

    try Data("first".utf8).write(to: firstURL)
    try Data("second-contents".utf8).write(to: secondURL)

    try volume.copyIn(hostPath: firstURL, toHFSPath: "overwrite")
    try volume.copyIn(hostPath: secondURL, toHFSPath: "overwrite")

    let info = try volume.attributes(of: "overwrite")
    #expect(info.dataForkSize == Data("second-contents".utf8).count)
}

@Test func largeFileCopyInOut() async throws {
    HFSKitSettings.verboseLoggingEnabled = false
    let volume = try makeWritableVolume()
    let tempDir = try makeTempDir()
    let largeURL = tempDir.appendingPathComponent("large.bin")
    let outputURL = tempDir.appendingPathComponent("large.out")

    let data = Data(repeating: 0xA5, count: 20000)
    try data.write(to: largeURL)

    try volume.copyIn(hostPath: largeURL, toHFSPath: "large.bin", mode: .raw)
    try volume.copyOut(hfsPath: "large.bin", toHostPath: outputURL, mode: .raw)

    let outData = try Data(contentsOf: outputURL)
    #expect(outData == data)
}

@Test func readOnlyDirectoryOperationsFail() async throws {
    HFSKitSettings.verboseLoggingEnabled = false
    let imgURL = try testImageURL()
    let volume = try HFSVolume(path: imgURL, writable: false)
    let tempDir = try makeTempDir()
    let sourceDir = tempDir.appendingPathComponent("RODir", isDirectory: true)
    let (_, _, _) = try createComplexHostDirectoryFixture(at: sourceDir)

    expectThrows {
        try volume.copyInDirectory(hostDirectory: sourceDir, toHFSPath: ":ReadOnlyDir")
    }
    expectThrows {
        try volume.deleteDirectory(path: ":System Folder")
    }
}

@Test func listTest2ImageContents() async throws {
    HFSKitSettings.verboseLoggingEnabled = false
    let imgURL = try test2ImageURL()
    let volume = try HFSVolume(path: imgURL, writable: false)

    let rootEntries = try volume.list(directory: ":")
    #expect(rootEntries.count == 3)

    let checksum = rootEntries.first { $0.name == "Checksum results" }
    #expect(checksum != nil)
    #expect(checksum?.isDirectory == false)
    #expect(checksum?.fileType == "TEXT")
    #expect(checksum?.fileCreator == "ttxt")

    let journey1987 = rootEntries.first { $0.name == "The Journey (1987)" }
    #expect(journey1987 != nil)
    #expect(journey1987?.isDirectory == true)

    let journey1988 = rootEntries.first { $0.name == "The Journey (1988)" }
    #expect(journey1988 != nil)
    #expect(journey1988?.isDirectory == true)

    for entry in rootEntries {
        #expect(!entry.path.isEmpty)
        _ = try volume.attributes(of: entry.path)
        if entry.isDirectory {
            _ = try volume.list(directory: entry.path)
        }
    }
}

@Test func copyOutDirectoryAndReimportJourney1988PreservesForkSizes() async throws {
    HFSKitSettings.verboseLoggingEnabled = false
    let sourceImageURL = try test2ImageURL()
    let sourceVolume = try HFSVolume(path: sourceImageURL, writable: false)
    let tempDir = try makeTempDir()
    let exportedDirectoryURL = tempDir.appendingPathComponent("Journey1988Export", isDirectory: true)
    let blankImageURL = tempDir.appendingPathComponent("journey-roundtrip.hda")

    let originalSnapshot = try snapshotSubtree(
        in: sourceVolume,
        at: ":The Journey (1988)"
    )
    #expect(
        originalSnapshot.values.contains(where: {
            !$0.isDirectory && $0.dataForkSize > 0 && $0.resourceForkSize > 0
        })
    )

    try sourceVolume.copyOutDirectory(
        hfsPath: ":The Journey (1988)",
        toHostDirectory: exportedDirectoryURL,
        mode: .auto
    )
    let exportedNames = try Set(FileManager.default.contentsOfDirectory(
        atPath: exportedDirectoryURL.path
    ))
    #expect(exportedNames.contains("The_Journey.bin"))
    #expect(exportedNames.contains(where: { $0.hasPrefix("Icon") && $0.hasSuffix(".bin") }))
    #expect(!exportedNames.contains("The Journey"))
    #expect(!exportedNames.contains(where: { $0 == "Icon" || $0 == "Icon " }))

    try HFSVolume.createBlank(path: blankImageURL, size: 8 * 1024 * 1024, volumeName: "JourneyRT")
    let importedVolume = try HFSVolume(path: blankImageURL, writable: true)
    try importedVolume.copyInDirectory(
        hostDirectory: exportedDirectoryURL,
        toHFSPath: ":Journey1988",
        mode: .auto
    )

    let importedSnapshot = try snapshotSubtree(
        in: importedVolume,
        at: ":Journey1988"
    )

    #expect(importedSnapshot.count == originalSnapshot.count)

    for (relativePath, original) in originalSnapshot {
        let imported = try #require(importedSnapshot[relativePath], "Missing path \(relativePath)")
        #expect(imported.isDirectory == original.isDirectory, "Directory mismatch at \(relativePath)")
        if !original.isDirectory {
            #expect(imported.dataForkSize == original.dataForkSize, "Data fork mismatch at \(relativePath)")
            #expect(imported.resourceForkSize == original.resourceForkSize, "Resource fork mismatch at \(relativePath)")
        }
    }
}

@Test func copyInMacBinaryAsRaw() async throws {
    HFSKitSettings.verboseLoggingEnabled = false
    let volume = try makeWritableVolume()
    let binURL = try sunglassesURL()

    try volume.copyIn(hostPath: binURL, toHFSPath: "sunglasses.bin", mode: .raw)
    let info = try volume.attributes(of: "sunglasses.bin")
    let binData = try Data(contentsOf: binURL)
    #expect(info.dataForkSize == binData.count)
    #expect(info.fileType == "????")
    #expect(info.fileCreator == "UNIX")
}

@Test func openMultiPartitionImageAndListRoot() async throws {
    HFSKitSettings.verboseLoggingEnabled = false
    let multiURL = try multiImageURL()
    let partitions = try HFSVolume.listPartitions(path: multiURL)
    let hfsPartitions = partitions.filter { $0.isHFS }

    #expect(hfsPartitions.count == 1)
    guard let hfsPartition = hfsPartitions.first else {
        throw HFSError.invalidArgument("Expected one HFS partition in multi.hda")
    }

    let defaultVolume = try HFSVolume(path: multiURL, writable: false)
    let defaultRootEntries = try defaultVolume.list(directory: ":")
    #expect(defaultRootEntries.isEmpty)

    let explicitVolume = try HFSVolume(path: multiURL, writable: false, partition: hfsPartition.index)
    let explicitRootEntries = try explicitVolume.list(directory: ":")
    #expect(explicitRootEntries.isEmpty)
    #expect(defaultRootEntries.count == explicitRootEntries.count)
}

@Test func macBinaryModeCopyInOutRoundTripAndRawControl() async throws {
    HFSKitSettings.verboseLoggingEnabled = false
    let volume = try makeWritableMultiVolume()
    let tempDir = try makeTempDir()
    let sampleURL = try macBinarySampleURL()
    let sampleData = try Data(contentsOf: sampleURL)

    try volume.copyIn(hostPath: sampleURL, toHFSPath: "macbinary.mode", mode: .macBinary)
    let modeInfo = try volume.attributes(of: "macbinary.mode")
    #expect(modeInfo.dataForkSize > 0)

    let modeOutURL = tempDir.appendingPathComponent("macbinary.mode.out.bin")
    try volume.copyOut(hfsPath: "macbinary.mode", toHostPath: modeOutURL, mode: .macBinary)
    #expect((try Data(contentsOf: modeOutURL)).count > 0)

    try volume.copyIn(hostPath: modeOutURL, toHFSPath: "macbinary.roundtrip", mode: .macBinary)
    let roundTripInfo = try volume.attributes(of: "macbinary.roundtrip")
    #expect(roundTripInfo.dataForkSize == modeInfo.dataForkSize)
    #expect(roundTripInfo.resourceForkSize == modeInfo.resourceForkSize)
    #expect(roundTripInfo.fileType == modeInfo.fileType)
    #expect(roundTripInfo.fileCreator == modeInfo.fileCreator)

    let modeRawOutURL2 = tempDir.appendingPathComponent("macbinary.roundtrip.raw")
    try volume.copyOut(hfsPath: "macbinary.roundtrip", toHostPath: modeRawOutURL2, mode: .raw)

    let modeRawOutURL = tempDir.appendingPathComponent("macbinary.mode.raw")
    try volume.copyOut(hfsPath: "macbinary.mode", toHostPath: modeRawOutURL, mode: .raw)
    #expect((try Data(contentsOf: modeRawOutURL)).count == modeInfo.dataForkSize)
    #expect(try Data(contentsOf: modeRawOutURL2) == Data(contentsOf: modeRawOutURL))

    try volume.copyIn(hostPath: sampleURL, toHFSPath: "macbinary.raw", mode: .raw)
    let rawInfo = try volume.attributes(of: "macbinary.raw")
    #expect(rawInfo.resourceForkSize == 0)
    #expect(rawInfo.dataForkSize == sampleData.count)
    #expect(modeInfo.dataForkSize != rawInfo.dataForkSize || modeInfo.resourceForkSize != rawInfo.resourceForkSize)
}

@Test func binHexModeCopyInOutRoundTripAndRawControl() async throws {
    HFSKitSettings.verboseLoggingEnabled = false
    try withBinHexLock {
        let volume = try makeWritableMultiVolume()
        let tempDir = try makeTempDir()
        let sampleURL = try binHexSampleURL()
        let sampleData = try Data(contentsOf: sampleURL)

        try volume.copyIn(hostPath: sampleURL, toHFSPath: "binhex.mode", mode: .binHex)
        let modeInfo = try volume.attributes(of: "binhex.mode")
        #expect(modeInfo.dataForkSize > 0)

        try volume.copyIn(hostPath: sampleURL, toHFSPath: "binhex_sample.hqx", mode: .binHex)
        expectThrows {
            _ = try volume.attributes(of: "binhex_sample.hqx")
        }
        _ = try volume.attributes(of: "binhex_sample")

        let modeOutURL = tempDir.appendingPathComponent("binhex.mode.out.hqx")
        try volume.copyOut(hfsPath: "binhex.mode", toHostPath: modeOutURL, mode: .binHex)
        #expect((try Data(contentsOf: modeOutURL)).count > 0)

        try volume.copyIn(hostPath: modeOutURL, toHFSPath: "binhex.roundtrip", mode: .binHex)
        let roundTripInfo = try volume.attributes(of: "binhex.roundtrip")
        #expect(roundTripInfo.dataForkSize == modeInfo.dataForkSize)
        #expect(roundTripInfo.resourceForkSize == modeInfo.resourceForkSize)
        #expect(roundTripInfo.fileType == modeInfo.fileType)
        #expect(roundTripInfo.fileCreator == modeInfo.fileCreator)

        let modeRawOutURL2 = tempDir.appendingPathComponent("binhex.roundtrip.raw")
        try volume.copyOut(hfsPath: "binhex.roundtrip", toHostPath: modeRawOutURL2, mode: .raw)

        let modeRawOutURL = tempDir.appendingPathComponent("binhex.mode.raw")
        try volume.copyOut(hfsPath: "binhex.mode", toHostPath: modeRawOutURL, mode: .raw)
        #expect((try Data(contentsOf: modeRawOutURL)).count == modeInfo.dataForkSize)
        #expect(try Data(contentsOf: modeRawOutURL2) == Data(contentsOf: modeRawOutURL))

        try volume.copyIn(hostPath: sampleURL, toHFSPath: "binhex.raw", mode: .raw)
        let rawInfo = try volume.attributes(of: "binhex.raw")
        #expect(rawInfo.resourceForkSize == 0)
        #expect(rawInfo.dataForkSize == sampleData.count)
        #expect(modeInfo.dataForkSize != rawInfo.dataForkSize || modeInfo.resourceForkSize != rawInfo.resourceForkSize)
    }
}

@Test func binHexCoreEncodeDecodeRoundTrip() async throws {
    HFSKitSettings.verboseLoggingEnabled = false
    try withBinHexLock {
        let tempDir = try makeTempDir()
        let rawInURL = tempDir.appendingPathComponent("binhex-core.raw")
        let hqxURL = tempDir.appendingPathComponent("binhex-core.hqx")
        let rawOutURL = tempDir.appendingPathComponent("binhex-core.out.raw")

        var bytes = Data((0..<2048).map { UInt8($0 & 0xff) })
        bytes.append(contentsOf: [0x90, 0x90, 0x90, 0x90, 0x90, 0x00, 0x90])
        try bytes.write(to: rawInURL)

        let encodeError = hfsw_test_binhex_encode_file(rawInURL.path, hqxURL.path)
        #expect(encodeError.code == 0, "\(describeCError(encodeError))")

        let decodeError = hfsw_test_binhex_decode_file(hqxURL.path, rawOutURL.path, bytes.count)
        #expect(decodeError.code == 0, "\(describeCError(decodeError))")

        let roundTrip = try Data(contentsOf: rawOutURL)
        #expect(roundTrip == bytes)
    }
}

@Test func binHexCoreDecodeDetectsCorruption() async throws {
    HFSKitSettings.verboseLoggingEnabled = false
    try withBinHexLock {
        let tempDir = try makeTempDir()
        let rawInURL = tempDir.appendingPathComponent("binhex-corrupt.raw")
        let hqxURL = tempDir.appendingPathComponent("binhex-corrupt.hqx")
        let rawOutURL = tempDir.appendingPathComponent("binhex-corrupt.out.raw")

        let bytes = Data((0..<1024).map { UInt8(($0 * 7) & 0xff) })
        try bytes.write(to: rawInURL)

        let encodeError = hfsw_test_binhex_encode_file(rawInURL.path, hqxURL.path)
        #expect(encodeError.code == 0, "\(describeCError(encodeError))")

        var hqxData = try Data(contentsOf: hqxURL)
        if let idx = hqxData.firstIndex(of: UInt8(ascii: ":")) {
            let payloadIdx = hqxData.index(after: idx)
            if payloadIdx < hqxData.endIndex {
                hqxData[payloadIdx] = UInt8(ascii: "A")
            }
        }
        try hqxData.write(to: hqxURL)

        let decodeError = hfsw_test_binhex_decode_file(hqxURL.path, rawOutURL.path, bytes.count)
        #expect(decodeError.code != 0)
    }
}

@Test func binHexCoreEncodeDecodeEmptyPayload() async throws {
    HFSKitSettings.verboseLoggingEnabled = false
    try withBinHexLock {
        let tempDir = try makeTempDir()
        let rawInURL = tempDir.appendingPathComponent("binhex-empty.raw")
        let hqxURL = tempDir.appendingPathComponent("binhex-empty.hqx")
        let rawOutURL = tempDir.appendingPathComponent("binhex-empty.out.raw")

        try Data().write(to: rawInURL)

        let encodeError = hfsw_test_binhex_encode_file(rawInURL.path, hqxURL.path)
        #expect(encodeError.code == 0, "\(describeCError(encodeError))")

        let decodeError = hfsw_test_binhex_decode_file(hqxURL.path, rawOutURL.path, 0)
        #expect(decodeError.code == 0, "\(describeCError(decodeError))")

        let roundTrip = try Data(contentsOf: rawOutURL)
        #expect(roundTrip.isEmpty)
    }
}

@Test func binHexCoreDecodeFailsWhenExpectedLengthIsWrong() async throws {
    HFSKitSettings.verboseLoggingEnabled = false
    try withBinHexLock {
        let tempDir = try makeTempDir()
        let rawInURL = tempDir.appendingPathComponent("binhex-wrong-length.raw")
        let hqxURL = tempDir.appendingPathComponent("binhex-wrong-length.hqx")
        let rawOutURL = tempDir.appendingPathComponent("binhex-wrong-length.out.raw")

        let bytes = Data((0..<256).map { UInt8($0 & 0xff) })
        try bytes.write(to: rawInURL)

        let encodeError = hfsw_test_binhex_encode_file(rawInURL.path, hqxURL.path)
        #expect(encodeError.code == 0, "\(describeCError(encodeError))")

        let decodeError = hfsw_test_binhex_decode_file(hqxURL.path, rawOutURL.path, bytes.count + 1)
        #expect(decodeError.code != 0)
    }
}

@Test func binHexCoreDecodeRejectsMissingHeader() async throws {
    HFSKitSettings.verboseLoggingEnabled = false
    try withBinHexLock {
        let tempDir = try makeTempDir()
        let invalidURL = tempDir.appendingPathComponent("not-hqx.hqx")
        let rawOutURL = tempDir.appendingPathComponent("not-hqx.out.raw")

        try Data("definitely not binhex".utf8).write(to: invalidURL)

        let decodeError = hfsw_test_binhex_decode_file(invalidURL.path, rawOutURL.path, 0)
        #expect(decodeError.code != 0)
    }
}

@Test func binHexCoreEncodeDecodeRandom1024RoundTrip() async throws {
    HFSKitSettings.verboseLoggingEnabled = false
    try withBinHexLock {
        let tempDir = try makeTempDir()
        let rawInURL = tempDir.appendingPathComponent("binhex-random-1024.raw")
        let hqxURL = tempDir.appendingPathComponent("binhex-random-1024.hqx")
        let rawOutURL = tempDir.appendingPathComponent("binhex-random-1024.out.raw")

        var generator = SystemRandomNumberGenerator()
        let bytes = Data((0..<1024).map { _ in UInt8.random(in: 0...255, using: &generator) })
        try bytes.write(to: rawInURL)

        let encodeError = hfsw_test_binhex_encode_file(rawInURL.path, hqxURL.path)
        #expect(encodeError.code == 0, "\(describeCError(encodeError))")

        let decodeError = hfsw_test_binhex_decode_file(hqxURL.path, rawOutURL.path, bytes.count)
        #expect(decodeError.code == 0, "\(describeCError(decodeError))")

        let roundTrip = try Data(contentsOf: rawOutURL)
        #expect(roundTrip == bytes)
    }
}

@Test func copyInMacBinaryRemovesBinExtensionFromDestinationName() async throws {
    HFSKitSettings.verboseLoggingEnabled = false
    let volume = try makeWritableMultiVolume()
    let sampleURL = try macBinarySampleURL()

    try volume.copyIn(hostPath: sampleURL,
                      toHFSPath: "macbinary_sample.smi_.bin",
                      mode: .macBinary)

    expectThrows {
        _ = try volume.attributes(of: "macbinary_sample.smi_.bin")
    }
    _ = try volume.attributes(of: "macbinary_sample.smi_")
}

@Test func textModeCopyInOutRoundTripAndRawControl() async throws {
    HFSKitSettings.verboseLoggingEnabled = false
    let volume = try makeWritableVolume()
    let tempDir = try makeTempDir()
    let sampleURL = try textSampleURL()
    let sampleData = try Data(contentsOf: sampleURL)

    try volume.copyIn(hostPath: sampleURL, toHFSPath: "text.mode", mode: .text)
    let modeInfo = try volume.attributes(of: "text.mode")
    #expect(modeInfo.resourceForkSize == 0)

    let modeOutURL = tempDir.appendingPathComponent("text.mode.out.txt")
    try volume.copyOut(hfsPath: "text.mode", toHostPath: modeOutURL, mode: .text)
    #expect(try Data(contentsOf: modeOutURL) == sampleData)

    try volume.copyIn(hostPath: sampleURL, toHFSPath: "text.raw", mode: .raw)
    let rawInfo = try volume.attributes(of: "text.raw")
    #expect(rawInfo.resourceForkSize == 0)
    #expect(rawInfo.dataForkSize == sampleData.count)

    let rawTextOutURL = tempDir.appendingPathComponent("text.raw.out.txt")
    try volume.copyOut(hfsPath: "text.raw", toHostPath: rawTextOutURL, mode: .text)
    #expect(try Data(contentsOf: rawTextOutURL) == sampleData)
}

@Test func macRomanDirectoryNameRoundTripAndList() async throws {
    HFSKitSettings.verboseLoggingEnabled = false
    let volume = try makeWritableVolume()
    let tempDir = try makeTempDir()
    let hostFile = tempDir.appendingPathComponent("host.txt")
    try Data("macroman".utf8).write(to: hostFile)

    try volume.makeDirectory(path: ":Café")
    try volume.copyIn(hostPath: hostFile, toHFSPath: ":Café:touché.txt", mode: .raw)

    let rootEntries = try volume.list(directory: ":")
    let cafe = try #require(rootEntries.first(where: { $0.name == "Café" }))
    #expect(cafe.isDirectory)

    let cafeEntries = try volume.list(directory: ":Café")
    let file = try #require(cafeEntries.first(where: { $0.name == "touché.txt" }))
    #expect(!file.isDirectory)

    let attrs = try volume.attributes(of: ":Café:touché.txt")
    #expect(attrs.name == "touché.txt")
    #expect(attrs.dataForkSize == Data("macroman".utf8).count)
}

private func testImageURL() throws -> URL {
    guard let imgURL = Bundle.module.url(forResource: "test", withExtension: "img") else {
        throw HFSError.invalidArgument("Missing test image resource")
    }
    return imgURL
}

private func mountainURL() throws -> URL {
    guard let url = Bundle.module.url(forResource: "mountain", withExtension: nil) else {
        throw HFSError.invalidArgument("Missing mountain resource")
    }
    return url
}

private func sunglassesURL() throws -> URL {
    guard let url = Bundle.module.url(forResource: "sunglasses", withExtension: "bin") else {
        throw HFSError.invalidArgument("Missing sunglasses resource")
    }
    return url
}

private func binHexSampleURL() throws -> URL {
    guard let url = Bundle.module.url(forResource: "binhex_sample", withExtension: "hqx") else {
        throw HFSError.invalidArgument("Missing binhex sample resource")
    }
    return url
}

private func macBinarySampleURL() throws -> URL {
    guard let url = Bundle.module.url(forResource: "macbinary_sample.smi_", withExtension: "bin") else {
        throw HFSError.invalidArgument("Missing macbinary sample resource")
    }
    return url
}

private func textSampleURL() throws -> URL {
    guard let url = Bundle.module.url(forResource: "text_sample", withExtension: "txt") else {
        throw HFSError.invalidArgument("Missing text sample resource")
    }
    return url
}

private func test2ImageURL() throws -> URL {
    guard let imgURL = Bundle.module.url(forResource: "test2", withExtension: "img") else {
        throw HFSError.invalidArgument("Missing test2 image resource")
    }
    return imgURL
}

private struct HFSTreeSnapshotEntry {
    let isDirectory: Bool
    let dataForkSize: Int
    let resourceForkSize: Int
}

private func snapshotSubtree(in volume: HFSVolume,
                             at rootPath: String,
                             relativePath: String = "") throws -> [String: HFSTreeSnapshotEntry]
{
    let info = try volume.attributes(of: rootPath)
    var snapshot: [String: HFSTreeSnapshotEntry] = [
        relativePath: HFSTreeSnapshotEntry(
            isDirectory: info.isDirectory,
            dataForkSize: info.dataForkSize,
            resourceForkSize: info.resourceForkSize
        )
    ]

    guard info.isDirectory else {
        return snapshot
    }

    for child in try volume.list(directory: rootPath).sorted(by: { $0.name < $1.name }) {
        let childRelativePath = relativePath.isEmpty ? child.name : "\(relativePath)/\(child.name)"
        let childHFSPath = joinHFSPathForTest(rootPath, child.name)
        let childSnapshot = try snapshotSubtree(
            in: volume,
            at: childHFSPath,
            relativePath: childRelativePath
        )
        for (key, value) in childSnapshot {
            snapshot[key] = value
        }
    }

    return snapshot
}

private func joinHFSPathForTest(_ base: String, _ component: String) -> String {
    if base.isEmpty || base == ":" {
        return ":\(component)"
    }
    return base.hasSuffix(":") ? "\(base)\(component)" : "\(base):\(component)"
}

private func multiImageURL() throws -> URL {
    guard let imgURL = Bundle.module.url(forResource: "multi", withExtension: "hda") else {
        throw HFSError.invalidArgument("Missing multi image resource")
    }
    return imgURL
}

private func makeTempDir() throws -> URL {
    let tempDir = FileManager.default.temporaryDirectory
        .appendingPathComponent("HFSKitTests-\(UUID())", isDirectory: true)
    try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    return tempDir
}

private func makeWritableVolume() throws -> HFSVolume {
    let imgURL = try testImageURL()
    let tempDir = try makeTempDir()
    let writableImageURL = tempDir.appendingPathComponent("test.img")
    try FileManager.default.copyItem(at: imgURL, to: writableImageURL)
    return try HFSVolume(path: writableImageURL, writable: true)
}

private func makeWritableMultiVolume() throws -> HFSVolume {
    let imgURL = try multiImageURL()
    let tempDir = try makeTempDir()
    let writableImageURL = tempDir.appendingPathComponent("multi.hda")
    try FileManager.default.copyItem(at: imgURL, to: writableImageURL)
    return try HFSVolume(path: writableImageURL, writable: true)
}

private func expectThrows(_ block: () throws -> Void) {
    do {
        try block()
        #expect(Bool(false))
    } catch {
        #expect(Bool(true))
    }
}

private func describeCError(_ err: HFSWError) -> String {
    if err.code == 0 {
        return "ok"
    }
    if let detail = err.detail {
        return "errno=\(err.code) detail=\(String(cString: detail))"
    }
    return "errno=\(err.code)"
}

private let binHexTestLock = NSLock()

private func withBinHexLock<T>(_ body: () throws -> T) throws -> T {
    binHexTestLock.lock()
    defer { binHexTestLock.unlock() }
    return try body()
}

private func createHostDirectoryFixture(at url: URL) throws -> (URL, URL) {
    let fm = FileManager.default
    try fm.createDirectory(at: url, withIntermediateDirectories: true)

    let rootFile = url.appendingPathComponent("root.txt")
    try Data("root file".utf8).write(to: rootFile)

    let subDir = url.appendingPathComponent("Sub", isDirectory: true)
    try fm.createDirectory(at: subDir, withIntermediateDirectories: true)

    let nestedFile = subDir.appendingPathComponent("nested.txt")
    try Data("nested file".utf8).write(to: nestedFile)

    return (rootFile, nestedFile)
}

private func createComplexHostDirectoryFixture(at url: URL) throws -> (URL, URL, URL) {
    let fm = FileManager.default
    try fm.createDirectory(at: url, withIntermediateDirectories: true)

    let rootFile = url.appendingPathComponent("root file.txt")
    try Data("root file".utf8).write(to: rootFile)

    let subDir = url.appendingPathComponent("Sub", isDirectory: true)
    try fm.createDirectory(at: subDir, withIntermediateDirectories: true)

    let nestedFile = subDir.appendingPathComponent("nested.txt")
    try Data("nested file".utf8).write(to: nestedFile)

    let emptyDir = url.appendingPathComponent("EmptyDir", isDirectory: true)
    try fm.createDirectory(at: emptyDir, withIntermediateDirectories: true)

    return (rootFile, nestedFile, emptyDir)
}
