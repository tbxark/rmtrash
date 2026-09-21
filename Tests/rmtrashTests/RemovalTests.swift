import XCTest
@testable import rmtrash

/// Non-interactive removal: -f / -r / -d, multiple operands, missing files,
/// and stat errors.
final class RemovalTests: CWDRestoringTestCase {

    /// Guards the test infrastructure itself: the file manager handed out by
    /// `createTempDirectory` must never call the real `trashItem`.
    func testTempDirectoryFileManagerDeletesInsteadOfTrashing() throws {
        let (fileManager, url) = FileManager.createTempDirectory()
        defer { try? fileManager.removeItem(at: url) }
        let testFM = try XCTUnwrap(fileManager as? TestFileManager)

        let file = url.appendingPathComponent("gone.txt")
        fileManager.createFile(atPath: file.path, contents: nil, attributes: nil)
        XCTAssertTrue(makeTrash(fileManager: fileManager).removeMultiple(paths: [file.path]))

        XCTAssertEqual(testFM.trashed.map { $0.standardizedFileURL.path }, [file.standardizedFileURL.path])
        XCTAssertNil(try fileManager.fileType(file))
    }

    func testForceConfig() {
        let (fileManager, url) = FileManager.createTempDirectory()
        defer { try? fileManager.removeItem(at: url) }

        let mockFiles: [FileNode] = [
            .file(name: "test.txt", content: "test content"),
            .directory(name: "dir1", sub: [
                .file(name: "file1.txt", content: "file1 content")
            ])
        ]
        fileManager.createFileStructure(nodes: mockFiles, at: url)

        let trash = makeTrash(force: true, fileManager: fileManager)
        XCTAssertTrue(trash.removeMultiple(paths: ["./test.txt"]))
        assertFileStructure(fileManager, at: url, expectedFiles: [
            .directory(name: "dir1", sub: [
                .file(name: "file1.txt", content: "file1 content")
            ])
        ])
    }

    func testRecursiveConfig() {
        let (fileManager, url) = FileManager.createTempDirectory()
        defer { try? fileManager.removeItem(at: url) }

        let mockFiles: [FileNode] = [
            .directory(name: "dir1", sub: [
                .file(name: "file1.txt", content: "file1 content"),
                .directory(name: "subdir", sub: [
                    .file(name: "file2.txt", content: "file2 content")
                ])
            ])
        ]
        fileManager.createFileStructure(nodes: mockFiles, at: url)

        // Test non-recursive config
        let nonRecursiveTrash = makeTrash(fileManager: fileManager)
        XCTAssertFalse(nonRecursiveTrash.removeMultiple(paths: ["./dir1"]))
        assertFileStructure(fileManager, at: url, expectedFiles: mockFiles)

        // Test recursive config
        let recursiveTrash = makeTrash(recursive: true, fileManager: fileManager)
        XCTAssertTrue(recursiveTrash.removeMultiple(paths: ["./dir1"]))
        assertFileStructure(fileManager, at: url, expectedFiles: [])
    }

    func testEmptyDirsConfig() {
        let (fileManager, url) = FileManager.createTempDirectory()
        defer { try? fileManager.removeItem(at: url) }

        let mockFiles: [FileNode] = [
            .directory(name: "emptyDir", sub: []),
            .directory(name: "nonEmptyDir", sub: [
                .file(name: "file.txt", content: "content")
            ])
        ]
        fileManager.createFileStructure(nodes: mockFiles, at: url)

        let trash = makeTrash(emptyDirs: true, fileManager: fileManager)
        XCTAssertTrue(trash.removeMultiple(paths: ["./emptyDir"]))
        assertFileStructure(fileManager, at: url, expectedFiles: [
            .directory(name: "nonEmptyDir", sub: [
                .file(name: "file.txt", content: "content")
            ])
        ])
        XCTAssertFalse(trash.removeMultiple(paths: ["./nonEmptyDir"]))
    }

    /// `-d` must refuse a directory it cannot read, even though it cannot prove
    /// the directory is non-empty (RF-001 regression).
    func testEmptyDirsRefusesUnreadableDirectory() throws {
        try XCTSkipIf(getuid() == 0, "root bypasses permission bits")
        let (fileManager, url) = FileManager.createTempDirectory()
        defer { try? fileManager.removeItem(at: url) }

        let locked = url.appendingPathComponent("locked")
        try fileManager.createDirectory(at: locked, withIntermediateDirectories: true)
        fileManager.createFile(atPath: locked.appendingPathComponent("secret.txt").path, contents: nil, attributes: nil)
        chmod(locked.path, 0)
        defer { chmod(locked.path, 0o755) }

        let trash = makeTrash(emptyDirs: true, fileManager: fileManager)
        XCTAssertFalse(trash.removeMultiple(paths: [locked.path]))
        XCTAssertEqual(try fileManager.fileType(locked), .typeDirectory)
    }

    func testSubDir() {
        let (fileManager, url) = FileManager.createTempDirectory()
        defer { try? fileManager.removeItem(at: url) }

        let initialFiles: [FileNode] = [
            .file(name: "test1.txt", content: "test1 content"),
            .file(name: "test2.txt", content: "test2 content"),
            .directory(name: "dir1", sub: [
                .file(name: "file1.txt", content: "file1 content"),
                .file(name: "file2.txt", content: "file2 content"),
                .directory(name: "subdir", sub: [
                    .file(name: "deep.txt", content: "deep content")
                ])
            ])
        ]
        fileManager.createFileStructure(nodes: initialFiles, at: url)
        let trash = makeTrash(force: true, fileManager: fileManager)

        XCTAssertTrue(trash.removeMultiple(paths: ["./dir1/file1.txt"]))
        fileManager.changeCurrentDirectoryPath("dir1")

        XCTAssertTrue(trash.removeMultiple(paths: ["./file2.txt"]))
        assertFileStructure(fileManager, at: url.appendingPathComponent("dir1"), expectedFiles: [
            .directory(name: "subdir", sub: [
                .file(name: "deep.txt", content: "deep content")
            ])
        ])
    }

    func testFileListStateAfterDeletion() {
        let (fileManager, url) = FileManager.createTempDirectory()
        defer { try? fileManager.removeItem(at: url) }

        let initialFiles: [FileNode] = [
            .file(name: "test1.txt", content: "test1 content"),
            .file(name: "test2.txt", content: "test2 content"),
            .directory(name: "dir1", sub: [
                .file(name: "file1.txt", content: "file1 content"),
                .file(name: "file2.txt", content: "file2 content"),
                .directory(name: "subdir", sub: [
                    .file(name: "deep.txt", content: "deep content")
                ])
            ])
        ]
        fileManager.createFileStructure(nodes: initialFiles, at: url)

        let trash = makeTrash(recursive: true, emptyDirs: true, fileManager: fileManager)

        // Test single file deletion
        XCTAssertTrue(trash.removeMultiple(paths: ["./test1.txt"]))
        assertFileStructure(fileManager, at: url, expectedFiles: [
            .file(name: "test2.txt", content: "test2 content"),
            .directory(name: "dir1", sub: [
                .file(name: "file1.txt", content: "file1 content"),
                .file(name: "file2.txt", content: "file2 content"),
                .directory(name: "subdir", sub: [
                    .file(name: "deep.txt", content: "deep content")
                ])
            ])
        ])

        // Test directory deletion
        XCTAssertTrue(trash.removeMultiple(paths: ["./dir1"]))
        assertFileStructure(fileManager, at: url, expectedFiles: [
            .file(name: "test2.txt", content: "test2 content")
        ])

        // Test remaining file deletion
        XCTAssertTrue(trash.removeMultiple(paths: ["./test2.txt"]))
        assertFileStructure(fileManager, at: url, expectedFiles: [])
    }

    func testMultipleFilesRemoval() {
        let (fileManager, url) = FileManager.createTempDirectory()
        defer { try? fileManager.removeItem(at: url) }

        let mockFiles: [FileNode] = [
            .file(name: "test1.txt", content: "test1 content"),
            .file(name: "test2.txt", content: "test2 content"),
            .file(name: "test3.txt", content: "test3 content"),
            .directory(name: "dir1", sub: [
                .file(name: "file1.txt", content: "file1 content")
            ]),
            .directory(name: "dir2", sub: [])
        ]
        fileManager.createFileStructure(nodes: mockFiles, at: url)

        let trash = makeTrash(
            force: true,
            recursive: true,
            emptyDirs: true,
            fileManager: fileManager
        )
        XCTAssertTrue(trash.removeMultiple(paths: [
            "./test1.txt",
            "./test2.txt",
            "./dir1",
            "./dir2"
        ]))

        assertFileStructure(fileManager, at: url, expectedFiles: [
            .file(name: "test3.txt", content: "test3 content")
        ])
    }

    func testNonExistentFiles() {
        let (fileManager, url) = FileManager.createTempDirectory()
        defer { try? fileManager.removeItem(at: url) }

        // Test with force = false
        let trashNoForce = makeTrash(force: false, fileManager: fileManager)
        XCTAssertFalse(trashNoForce.removeMultiple(paths: ["./nonexistent.txt"]))

        // Test with force = true
        let trashForce = makeTrash(force: true, fileManager: fileManager)
        XCTAssertTrue(trashForce.removeMultiple(paths: ["./nonexistent.txt"]))
    }

    /// `-f` only silences "does not exist". A file that cannot be stat'ed for
    /// another reason (here: unsearchable parent) is a failure with or without
    /// `-f`, matching rm (RF-002 regression).
    func testPermissionDeniedIsReportedEvenWithForce() throws {
        try XCTSkipIf(getuid() == 0, "root bypasses permission bits")
        let (fileManager, url) = FileManager.createTempDirectory()
        defer { try? fileManager.removeItem(at: url) }

        let parent = url.appendingPathComponent("p")
        try fileManager.createDirectory(at: parent, withIntermediateDirectories: true)
        let child = parent.appendingPathComponent("f")
        fileManager.createFile(atPath: child.path, contents: nil, attributes: nil)
        chmod(parent.path, 0)
        defer { chmod(parent.path, 0o755) }

        XCTAssertFalse(makeTrash(force: false, fileManager: fileManager).removeMultiple(paths: [child.path]))
        XCTAssertFalse(makeTrash(force: true, fileManager: fileManager).removeMultiple(paths: [child.path]))
    }
}
