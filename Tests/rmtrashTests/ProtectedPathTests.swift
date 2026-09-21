import XCTest
@testable import rmtrash

/// Paths rmtrash refuses to touch: the filesystem root and `.` / `..`.
final class ProtectedPathTests: CWDRestoringTestCase {

    // MARK: - Preserve root

    /// `--preserve-root` (the default) refuses the filesystem root; turning it off
    /// allows the removal. Uses a mock root so no real directory is at risk.
    func testPreserveRootRefusesRootDirectory() {
        let (real, url) = FileManager.createTempDirectory()
        defer { try? real.removeItem(at: url) }
        let dir = url.appendingPathComponent("rootlike")
        try? real.createDirectory(at: dir, withIntermediateDirectories: true, attributes: nil)

        let mock = RecordingFileManager()
        mock.roots = [dir.standardizedFileURL.path]

        let guarded = makeTrash(recursive: true, preserveRoot: true, fileManager: mock)
        XCTAssertFalse(guarded.removeMultiple(paths: [dir.path]))
        XCTAssertEqual(try mock.fileType(dir), .typeDirectory)

        let unguarded = makeTrash(recursive: true, preserveRoot: false, fileManager: mock)
        XCTAssertTrue(unguarded.removeMultiple(paths: [dir.path]))
        XCTAssertNil(try mock.fileType(dir))
    }

    /// A symlink pointing at the root directory is just a link: `-r` removes
    /// the link and never reaches the root, with or without a trailing slash.
    /// Uses a mock root so the real `/` is never involved.
    func testSymlinkToRootRemovesOnlyTheLink() throws {
        let (real, url) = FileManager.createTempDirectory()
        defer { try? real.removeItem(at: url) }
        let rootlike = url.appendingPathComponent("rootlike")
        try real.createDirectory(at: rootlike, withIntermediateDirectories: true)
        real.createFile(atPath: rootlike.appendingPathComponent("etc").path, contents: nil, attributes: nil)
        let link = url.appendingPathComponent("rootlink")
        try real.createSymbolicLink(at: link, withDestinationURL: rootlike)

        let mock = RecordingFileManager()
        mock.roots = [rootlike.standardizedFileURL.path]
        let trash = makeTrash(recursive: true, preserveRoot: true, fileManager: mock)

        XCTAssertTrue(trash.removeMultiple(paths: [link.path + "/"]))
        XCTAssertEqual(mock.removed, ["rootlink"])
        XCTAssertNil(try mock.fileType(link))
        XCTAssertEqual(try mock.fileType(rootlike.appendingPathComponent("etc")), .typeRegular)
    }

    // MARK: - '.' and '..'

    func testProtectedOperands() {
        let (fileManager, url) = FileManager.createTempDirectory()
        defer { try? fileManager.removeItem(at: url) }

        let mockFiles: [FileNode] = [
            .file(name: "test.txt", content: "test content")
        ]
        fileManager.createFileStructure(nodes: mockFiles, at: url)

        let trash = makeTrash(force: false, recursive: true, fileManager: fileManager)

        // Test basic protected paths
        XCTAssertFalse(trash.removeMultiple(paths: ["."]))
        XCTAssertFalse(trash.removeMultiple(paths: [".."]))

        // Test extended protected paths
        XCTAssertFalse(trash.removeMultiple(paths: ["./."]))
        XCTAssertFalse(trash.removeMultiple(paths: ["../.."]))
        XCTAssertFalse(trash.removeMultiple(paths: ["../../"]))

        // Verify files still exist
        assertFileStructure(fileManager, at: url, expectedFiles: mockFiles)
    }

    func testProtectedOperandsTrailingSlash() {
        // GNU rm refuses '.' and '..' regardless of trailing slashes.
        // basename-based detection covers foo/./, foo/../, /., /.., etc.
        let (fileManager, url) = FileManager.createTempDirectory()
        defer { try? fileManager.removeItem(at: url) }

        let mockFiles: [FileNode] = [
            .file(name: "test.txt", content: "test content")
        ]
        fileManager.createFileStructure(nodes: mockFiles, at: url)

        let trash = makeTrash(force: false, recursive: true, fileManager: fileManager)

        XCTAssertFalse(trash.removeMultiple(paths: ["./"]))
        XCTAssertFalse(trash.removeMultiple(paths: ["../"]))
        XCTAssertFalse(trash.removeMultiple(paths: ["foo/./"]))
        XCTAssertFalse(trash.removeMultiple(paths: ["foo/../"]))
        XCTAssertFalse(trash.removeMultiple(paths: ["/."]))
        XCTAssertFalse(trash.removeMultiple(paths: ["/.."]))

        assertFileStructure(fileManager, at: url, expectedFiles: mockFiles)
    }
}
