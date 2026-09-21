import XCTest
@testable import rmtrash

/// The real `FileManager` conformance to `FileManagerType`.
final class FileManagerTests: CWDRestoringTestCase {

    func testIsRootDir() throws {
        let (fileManager, url) = FileManager.createTempDirectory()
        defer { try? fileManager.removeItem(at: url) }

        XCTAssertTrue(fileManager.isRootDir(URL(fileURLWithPath: "/")))
        XCTAssertFalse(fileManager.isRootDir(url))
    }

    func testIsEmptyDirectory() {
        let (fileManager, url) = FileManager.createTempDirectory()
        defer { try? fileManager.removeItem(at: url) }

        // Empty directory
        XCTAssertTrue(fileManager.isEmptyDirectory(url))

        // Directory with a file
        let fileURL = url.appendingPathComponent("test.txt")
        fileManager.createFile(atPath: fileURL.path, contents: nil, attributes: nil)
        XCTAssertFalse(fileManager.isEmptyDirectory(url))
    }

    /// An unreadable directory must be reported as non-empty: the `-d` guard
    /// relies on this to refuse trashing a directory whose contents it cannot see.
    func testUnreadableDirectoryIsNotEmpty() throws {
        try XCTSkipIf(getuid() == 0, "root bypasses permission bits")
        let (fileManager, url) = FileManager.createTempDirectory()
        defer { try? fileManager.removeItem(at: url) }

        let locked = url.appendingPathComponent("locked")
        try fileManager.createDirectory(at: locked, withIntermediateDirectories: true)
        fileManager.createFile(atPath: locked.appendingPathComponent("secret.txt").path, contents: nil, attributes: nil)
        chmod(locked.path, 0)
        defer { chmod(locked.path, 0o755) }

        XCTAssertFalse(fileManager.isEmptyDirectory(locked))
    }

    func testFileTypeDetection() {
        let (fileManager, url) = FileManager.createTempDirectory()
        defer { try? fileManager.removeItem(at: url) }

        XCTAssertNil(try fileManager.fileType(url.appendingPathComponent("no_file")))

        let fileURL = url.appendingPathComponent("temp.txt")
        fileManager.createFile(atPath: fileURL.path, contents: nil, attributes: nil)
        XCTAssertEqual(try fileManager.fileType(fileURL), .typeRegular)
        XCTAssertEqual(try fileManager.fileType(url), .typeDirectory)
    }

    /// `fileType` returns nil only for ENOENT; other stat failures are thrown
    /// with a POSIX description so callers can tell them apart.
    func testFileTypeDistinguishesMissingFromUnreadable() throws {
        try XCTSkipIf(getuid() == 0, "root bypasses permission bits")
        let (fileManager, url) = FileManager.createTempDirectory()
        defer { try? fileManager.removeItem(at: url) }

        let parent = url.appendingPathComponent("p")
        try fileManager.createDirectory(at: parent, withIntermediateDirectories: true)
        let child = parent.appendingPathComponent("f")
        fileManager.createFile(atPath: child.path, contents: nil, attributes: nil)
        chmod(parent.path, 0)
        defer { chmod(parent.path, 0o755) }

        XCTAssertNil(try fileManager.fileType(url.appendingPathComponent("missing")))
        XCTAssertThrowsError(try fileManager.fileType(child)) { error in
            XCTAssertEqual(error.posixCode, EACCES)
            XCTAssertEqual(error.rmDescription, "Permission denied")
        }
    }

    func testCrossMountPointDetection() throws {
        let (fileManager, url) = FileManager.createTempDirectory()
        defer { try? fileManager.removeItem(at: url) }

        // Same volume against itself / its descendants
        let subDir = url.appendingPathComponent("subdir")
        try fileManager.createDirectory(at: subDir, withIntermediateDirectories: true, attributes: nil)

        XCTAssertFalse(try fileManager.isCrossMountPoint(subDir, against: url))
        XCTAssertFalse(try fileManager.isCrossMountPoint(url, against: url))

        // Cross-volume check only runs if tmp and / are actually on different volumes.
        let rootURL = URL(fileURLWithPath: "/")
        let tempVol = try url.resourceValues(forKeys: [.volumeURLKey])
        let rootVol = try rootURL.resourceValues(forKeys: [.volumeURLKey])
        if tempVol.volume != rootVol.volume {
            XCTAssertTrue(try fileManager.isCrossMountPoint(rootURL, against: url))
        }
    }
}
