import XCTest
@testable import rmtrash

/// Mock file manager for simulating different volumes. Volumes are assigned by
/// path prefix; isCrossMountPoint compares the volume of `url` against the volume
/// of the supplied `base`, exercising the rm semantics of "compare against the
/// command-line argument". Everything else is the real filesystem.
final class MockVolumeFileManager: FileManagerType {
    private let baseFileManager = TestFileManager()
    private var volumeMap: [String: String] = [:]

    func setVolume(_ volumeId: String, for path: String) {
        volumeMap[path] = volumeId
    }

    private func volume(for url: URL) -> String? {
        let path = url.standardizedFileURL.path
        // Longest-prefix match so /a/b/c picks /a/b over /a.
        return volumeMap
            .filter { path == $0.key || path.hasPrefix($0.key.hasSuffix("/") ? $0.key : $0.key + "/") }
            .max(by: { $0.key.count < $1.key.count })?
            .value
    }

    func trashItem(at url: URL) throws {
        // Test double: delete outright so tests never pollute the real Trash.
        try baseFileManager.removeItem(at: url)
    }

    func isRootDir(_ url: URL) -> Bool {
        return baseFileManager.isRootDir(url)
    }

    func isEmptyDirectory(_ url: URL) -> Bool {
        return baseFileManager.isEmptyDirectory(url)
    }

    func isCrossMountPoint(_ url: URL, against base: URL) throws -> Bool {
        let urlVol = volume(for: url)
        let baseVol = volume(for: base)
        // If neither path is mapped, treat as same volume (no info).
        if urlVol == nil && baseVol == nil { return false }
        return urlVol != baseVol
    }

    func fileType(_ url: URL) throws -> FileAttributeType? {
        return try baseFileManager.fileType(url)
    }

    func subpaths(atPath path: String, enumerator handler: (String) -> Bool) {
        baseFileManager.subpaths(atPath: path, enumerator: handler)
    }
}

/// `-x` / `--one-file-system`: a command-line directory spanning a mount point
/// is refused as a whole.
final class OneFileSystemTests: CWDRestoringTestCase {

    func testVolumeSimulation() throws {
        // Sanity-check the mock's volume bookkeeping: a URL on a different volume
        // than the base should be reported as cross-mount; a URL on the same volume
        // as the base (even if the *CWD* is on yet another volume) should not.
        // This protects against the regression of comparing against CWD instead of
        // the command-line argument.
        let mockFM = MockVolumeFileManager()
        mockFM.setVolume("volA", for: "/baseA")
        mockFM.setVolume("volA", for: "/baseA/child.txt")
        mockFM.setVolume("volB", for: "/baseB")

        let baseA = URL(fileURLWithPath: "/baseA")
        let baseB = URL(fileURLWithPath: "/baseB")
        let childA = URL(fileURLWithPath: "/baseA/child.txt")

        // Same volume relative to the supplied base.
        XCTAssertFalse(try mockFM.isCrossMountPoint(childA, against: baseA))
        // Different volume relative to the supplied base.
        XCTAssertTrue(try mockFM.isCrossMountPoint(childA, against: baseB))
        // Base compared against itself is never cross-mount.
        XCTAssertFalse(try mockFM.isCrossMountPoint(baseA, against: baseA))
    }

    func testOneFileSystemRefusesDirectorySpanningMountPoint() throws {
        // With --one-file-system, a command-line directory that spans a mount
        // point is refused as a whole: nothing beneath it is removed, so a nested
        // volume is never swept into the Trash. This is exercised on the common
        // non-interactive path (`rmtrash -rfx dir`) — not just interactive walks.
        let (fileManager, url) = FileManager.createTempDirectory()
        defer { try? fileManager.removeItem(at: url) }

        fileManager.createFileStructure(nodes: [
            .directory(name: "root", sub: [
                .file(name: "same_vol.txt", content: "a"),
                .file(name: "cross_vol.txt", content: "b")
            ])
        ], at: url)

        let rootPath = url.appendingPathComponent("root").path
        let sameVolPath = url.appendingPathComponent("root/same_vol.txt").path
        let crossVolPath = url.appendingPathComponent("root/cross_vol.txt").path

        let mockFM = MockVolumeFileManager()
        mockFM.setVolume("volRoot", for: rootPath)
        mockFM.setVolume("volRoot", for: sameVolPath)
        mockFM.setVolume("volOther", for: crossVolPath)

        let trash = makeTrash(
            interactiveMode: .never,
            force: true,
            recursive: true,
            oneFileSystem: true,
            fileManager: mockFM,
            question: StaticAnswer(value: true)
        )

        XCTAssertFalse(trash.removeMultiple(paths: [rootPath]))
        // Nothing removed: both files and the directory itself remain.
        XCTAssertEqual(try mockFM.fileType(URL(fileURLWithPath: crossVolPath)), .typeRegular)
        XCTAssertEqual(try mockFM.fileType(URL(fileURLWithPath: sameVolPath)), .typeRegular)
        XCTAssertEqual(try mockFM.fileType(URL(fileURLWithPath: rootPath)), .typeDirectory)
    }

    /// The whole-argument refusal applies in interactive mode too: the user is
    /// never even asked to descend into a directory that spans a mount point.
    func testOneFileSystemRefusesSpanningDirectoryBeforePromptingInteractively() throws {
        let (fileManager, url) = FileManager.createTempDirectory()
        defer { try? fileManager.removeItem(at: url) }

        fileManager.createFileStructure(nodes: [
            .directory(name: "root", sub: [
                .file(name: "same_vol.txt", content: "a"),
                .directory(name: "mnt", sub: [.file(name: "cross_vol.txt", content: "b")])
            ])
        ], at: url)

        let rootPath = url.appendingPathComponent("root").path
        let mockFM = MockVolumeFileManager()
        mockFM.setVolume("volRoot", for: rootPath)
        mockFM.setVolume("volOther", for: url.appendingPathComponent("root/mnt").path)

        let q = RecordingQuestion(answer: true)
        let trash = makeTrash(interactiveMode: .always, force: false, recursive: true,
                              oneFileSystem: true, fileManager: mockFM, question: q)

        XCTAssertFalse(trash.removeMultiple(paths: [rootPath]))
        XCTAssertTrue(q.asked.isEmpty)
        XCTAssertEqual(try mockFM.fileType(URL(fileURLWithPath: rootPath + "/same_vol.txt")), .typeRegular)
        XCTAssertEqual(try mockFM.fileType(URL(fileURLWithPath: rootPath + "/mnt/cross_vol.txt")), .typeRegular)
    }

    func testOneFileSystemAllowsSingleVolumeDirectory() throws {
        // --one-file-system must not block a directory that lives entirely on one
        // volume; the whole tree is removed normally.
        let (fileManager, url) = FileManager.createTempDirectory()
        defer { try? fileManager.removeItem(at: url) }

        fileManager.createFileStructure(nodes: [
            .directory(name: "root", sub: [
                .file(name: "a.txt", content: "a"),
                .directory(name: "sub", sub: [
                    .file(name: "b.txt", content: "b")
                ])
            ])
        ], at: url)

        let rootPath = url.appendingPathComponent("root").path
        let mockFM = MockVolumeFileManager()
        // The whole subtree resolves to volRoot via longest-prefix match.
        mockFM.setVolume("volRoot", for: rootPath)

        let trash = makeTrash(
            interactiveMode: .never,
            force: true,
            recursive: true,
            oneFileSystem: true,
            fileManager: mockFM,
            question: StaticAnswer(value: true)
        )

        XCTAssertTrue(trash.removeMultiple(paths: [rootPath]))
        XCTAssertNil(try mockFM.fileType(URL(fileURLWithPath: rootPath)))
    }
}
