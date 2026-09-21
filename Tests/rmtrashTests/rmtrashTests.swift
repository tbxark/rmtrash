import XCTest
@testable import rmtrash

enum FileNode: Equatable, Comparable {

    case file(name: String, content: String? = nil)
    case directory(name: String, sub: [FileNode])
    case symbolicLink(name: String, target: String)
    case hardLink(name: String, target: String)

    var name: String {
        switch self {
        case .file(let name, _): return name
        case .directory(let name, _): return name
        case .symbolicLink(let name, _): return name
        case .hardLink(let name, _): return name
        }
    }

    var isDirectory: Bool {
        switch self {
        case .file, .symbolicLink, .hardLink: return false
        case .directory: return true
        }
    }

    static func < (lhs: FileNode, rhs: FileNode) -> Bool {
        return lhs.name < rhs.name
    }

    static func ==(lhs: FileNode, rhs: FileNode) -> Bool {
        switch (lhs, rhs) {
        case (.file(let l, let lc), .file(let r, let rc)):
            return l == r && lc == rc
        case (.directory(let l, let ls), .directory(let r, let rs)):
            guard l == r else { return false }
            let lss = ls.sorted()
            let rss = rs.sorted()
            if lss.count != rss.count { return false }
            return zip(lss, rss).allSatisfy(==)
        case (.symbolicLink(let l, let lt), .symbolicLink(let r, let rt)):
            return l == r && lt == rt
        case (.hardLink(let l, let lt), .hardLink(let r, let rt)):
            return l == r && lt == rt
        default:
            return false
        }
    }
}

extension Array where Element == FileNode {
    static func == (lhs: Self, rhs: Self) -> Bool {
        guard lhs.count == rhs.count else { return false }
        let lss = lhs.sorted()
        let rss = rhs.sorted()
        return zip(lss, rss).allSatisfy(==)
    }
}

struct StaticAnswer: Question {
    let value: Bool
    func ask(_ message: String) -> Bool {
        return value
    }
}

/// Records every prompt it is asked, so tests can assert whether (and how often)
/// the user was prompted.
final class RecordingQuestion: Question {
    let answer: Bool
    private(set) var asked: [String] = []
    init(answer: Bool) { self.answer = answer }
    func ask(_ message: String) -> Bool {
        asked.append(message)
        return answer
    }
}

/// A `FileManagerType` for deterministic removal tests. Inspection (type,
/// emptiness, enumeration) runs against the real filesystem, but "trashing"
/// permanently deletes the item — so tests never pollute the user's real Trash —
/// and can be told to fail for specific basenames to exercise error-handling
/// paths. Enumeration is sorted so tests can reason about child ordering.
final class RecordingFileManager: FileManagerType {
    private let real = TestFileManager()

    /// Basenames for which `trashItem` throws instead of removing.
    var failing: Set<String> = []
    /// Basenames for which `trashItem` was attempted, in call order.
    private(set) var attempted: [String] = []
    /// Basenames actually removed, in call order.
    private(set) var removed: [String] = []
    /// Absolute paths that should be reported as the filesystem root.
    var roots: Set<String> = []

    func trashItem(at url: URL) throws {
        let name = url.lastPathComponent
        attempted.append(name)
        if failing.contains(name) {
            throw Panic("simulated failure removing \(name)")
        }
        try real.removeItem(at: url)
        removed.append(name)
    }

    func isRootDir(_ url: URL) -> Bool {
        roots.contains(url.standardizedFileURL.path) || real.isRootDir(url)
    }
    func isEmptyDirectory(_ url: URL) -> Bool { real.isEmptyDirectory(url) }
    func isCrossMountPoint(_ url: URL, against base: URL) throws -> Bool { false }
    func fileType(_ url: URL) throws -> FileAttributeType? { try real.fileType(url) }

    func subpaths(atPath path: String, enumerator handler: (String) -> Bool) {
        guard let names = try? real.contentsOfDirectory(atPath: path) else { return }
        for name in names.sorted() {
            let child = URL(fileURLWithPath: path).appendingPathComponent(name).path
            if !handler(child) { break }
        }
    }
}

/// A `FileManager` whose `trashItem` deletes the item outright instead of moving
/// it to `~/.Trash`. Every other method (stat, enumeration, emptiness, volume
/// lookup) is the real implementation, so tests exercise the production code
/// paths without leaving anything in the user's Trash.
final class TestFileManager: FileManager {
    /// URLs that were "trashed" (deleted), in call order.
    private(set) var trashed: [URL] = []

    override func trashItem(at url: URL, resultingItemURL outResultingURL: AutoreleasingUnsafeMutablePointer<NSURL?>?) throws {
        try removeItem(at: url)
        trashed.append(url)
        outResultingURL?.pointee = nil
    }
}

/// Restores the process working directory after each test, since
/// `createTempDirectory` changes it and the tests share one process.
class CWDRestoringTestCase: XCTestCase {
    private var originalCWD = ""

    override func setUp() {
        super.setUp()
        originalCWD = FileManager.default.currentDirectoryPath
    }

    override func tearDown() {
        FileManager.default.changeCurrentDirectoryPath(originalCWD)
        super.tearDown()
    }
}

extension FileManager {
    func currentFileStructure(at url: URL) -> FileNode? {
        guard let attr = try? attributesOfItem(atPath: url.path),
              let type = attr[.type] as? FileAttributeType else {
            return nil
        }
        
        switch type {
        case .typeDirectory:
            var sub = [FileNode]()
            guard let paths = try? contentsOfDirectory(at: url, includingPropertiesForKeys: nil) else {
                return nil
            }
            for path in paths {
                if let node = currentFileStructure(at: url.appendingPathComponent(path.lastPathComponent)) {
                    sub.append(node)
                }
            }
            return FileNode.directory(name: url.lastPathComponent, sub: sub)
        case .typeSymbolicLink:
            let target = (try? destinationOfSymbolicLink(atPath: url.path)) ?? ""
            return FileNode.symbolicLink(name: url.lastPathComponent, target: target)
        case .typeRegular:
            let content = try? String(contentsOf: url, encoding: .utf8)
            return FileNode.file(name: url.lastPathComponent, content: content)
        default:
            return FileNode.file(name: url.lastPathComponent, content: nil)
        }
    }

    func createFileStructure(node: FileNode, at url: URL) {
        switch node {
        case .file(let name, let content):
            let fileURL = url.appendingPathComponent(name)
            let data = content?.data(using: .utf8)
            createFile(atPath: fileURL.path, contents: data, attributes: nil)
        case .directory(let name, let sub):
            let dirUrl = url.appendingPathComponent(name)
            try? createDirectory(at: dirUrl, withIntermediateDirectories: true, attributes: nil)
            for node in sub {
                createFileStructure(node: node, at: dirUrl)
            }
        case .symbolicLink(let name, let target):
            let linkURL = url.appendingPathComponent(name)
            let targetURL = URL(fileURLWithPath: target, relativeTo: url)
            try? createSymbolicLink(at: linkURL, withDestinationURL: targetURL)
        case .hardLink(let name, let target):
            let linkURL = url.appendingPathComponent(name)
            let targetURL = url.appendingPathComponent(target)
            try? linkItem(at: targetURL, to: linkURL)
        }
    }

    func createFileStructure(nodes: [FileNode], at url: URL) {
        for node in nodes {
            createFileStructure(node: node, at: url)
        }
    }

    /// Creates a fresh temp directory, makes it the CWD, and returns a
    /// `TestFileManager` (deletes instead of trashing) rooted there.
    static func createTempDirectory() -> (fileManager: FileManager, url: URL) {
        let fileManager = TestFileManager()
        let tempDir = fileManager.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try? fileManager.createDirectory(at: tempDir, withIntermediateDirectories: true, attributes: nil)
        fileManager.changeCurrentDirectoryPath(tempDir.path)
        return (fileManager, tempDir)
    }
}

// MARK: - Test Infrastructure Enhancements

/// Comprehensive test utilities for file system simulation
struct FileSystemTestUtilities {
    
    /// Generate complex symbolic link scenarios for testing
    struct SymbolicLinkGenerator {
        
        /// Generate a chain of symbolic links (A -> B -> C -> target)
        static func generateLinkChain(length: Int, baseName: String = "link") -> [FileNode] {
            guard length > 0 else { return [] }
            
            var nodes: [FileNode] = []
            let targetFile = FileNode.file(name: "target.txt", content: "target content")
            nodes.append(targetFile)
            
            var previousTarget = "target.txt"
            for i in 1...length {
                let linkName = "\(baseName)\(i).link"
                nodes.append(FileNode.symbolicLink(name: linkName, target: previousTarget))
                previousTarget = linkName
            }
            
            return nodes
        }
        
        /// Generate circular symbolic links (A -> B -> A)
        static func generateCircularLinks() -> [FileNode] {
            return [
                FileNode.symbolicLink(name: "link_a.link", target: "link_b.link"),
                FileNode.symbolicLink(name: "link_b.link", target: "link_a.link")
            ]
        }
        
        /// Generate broken symbolic links (pointing to non-existent targets)
        static func generateBrokenLinks() -> [FileNode] {
            return [
                FileNode.symbolicLink(name: "broken1.link", target: "nonexistent.txt"),
                FileNode.symbolicLink(name: "broken2.link", target: "../outside/file.txt"),
                FileNode.symbolicLink(name: "broken3.link", target: "/absolute/nonexistent.txt")
            ]
        }
        
        /// Generate mixed link scenarios (symbolic + hard links)
        static func generateMixedLinkScenario() -> [FileNode] {
            return [
                FileNode.file(name: "original.txt", content: "original content"),
                FileNode.hardLink(name: "hard1.txt", target: "original.txt"),
                FileNode.hardLink(name: "hard2.txt", target: "original.txt"),
                FileNode.symbolicLink(name: "sym_to_original.link", target: "original.txt"),
                FileNode.symbolicLink(name: "sym_to_hard.link", target: "hard1.txt"),
                FileNode.directory(name: "subdir", sub: [
                    FileNode.symbolicLink(name: "sym_to_parent.link", target: "../original.txt")
                ])
            ]
        }
        
        /// Generate absolute vs relative symbolic links
        static func generateAbsoluteRelativeLinks(baseURL: URL) -> [FileNode] {
            let absoluteTarget = baseURL.appendingPathComponent("target.txt").path
            return [
                FileNode.file(name: "target.txt", content: "target content"),
                FileNode.symbolicLink(name: "relative.link", target: "target.txt"),
                FileNode.symbolicLink(name: "absolute.link", target: absoluteTarget),
                FileNode.directory(name: "subdir", sub: [
                    FileNode.symbolicLink(name: "relative_up.link", target: "../target.txt"),
                    FileNode.symbolicLink(name: "absolute_from_sub.link", target: absoluteTarget)
                ])
            ]
        }
    }
    
    /// Volume and mount point simulation utilities
    struct VolumeSimulator {
        
        /// Mock file manager for simulating different volumes. Volumes are assigned by
        /// path prefix; isCrossMountPoint compares the volume of `url` against the volume
        /// of the supplied `base`, exercising the rm semantics of "compare against the
        /// command-line argument".
        class MockVolumeFileManager: FileManagerType {
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
    }
    
    /// Complex file system scenario generators
    struct ScenarioGenerator {
        
        /// Generate a deep directory hierarchy with mixed file types
        static func generateDeepHierarchy(depth: Int, filesPerLevel: Int = 2) -> FileNode {
            func createLevel(currentDepth: Int, name: String) -> FileNode {
                if currentDepth >= depth {
                    return FileNode.file(name: name, content: "content at depth \(currentDepth)")
                }
                
                var children: [FileNode] = []
                
                // Add files at this level
                for i in 0..<filesPerLevel {
                    children.append(FileNode.file(name: "file\(i)_d\(currentDepth).txt", 
                                                content: "file \(i) at depth \(currentDepth)"))
                }
                
                // Add subdirectory
                children.append(createLevel(currentDepth: currentDepth + 1, 
                                          name: "subdir_d\(currentDepth + 1)"))
                
                // Add some links at deeper levels
                if currentDepth > 0 {
                    children.append(FileNode.symbolicLink(name: "link_d\(currentDepth).link", 
                                                        target: "file0_d\(currentDepth).txt"))
                }
                
                return FileNode.directory(name: name, sub: children)
            }
            
            return createLevel(currentDepth: 0, name: "root")
        }
        
        /// Generate a scenario with permission-like issues (empty dirs, special files)
        static func generatePermissionScenario() -> [FileNode] {
            return [
                FileNode.directory(name: "empty_dir", sub: []),
                FileNode.directory(name: "nested_empty", sub: [
                    FileNode.directory(name: "inner_empty", sub: [])
                ]),
                FileNode.directory(name: "mixed_content", sub: [
                    FileNode.file(name: "regular.txt", content: "regular content"),
                    FileNode.directory(name: "empty_sub", sub: []),
                    FileNode.symbolicLink(name: "broken.link", target: "nonexistent.txt")
                ]),
                FileNode.file(name: "readonly_sim.txt", content: "readonly simulation"),
                FileNode.symbolicLink(name: "self_ref.link", target: ".")
            ]
        }
        
        /// Generate a large file system for performance testing
        static func generateLargeFileSystem(dirCount: Int, fileCount: Int) -> [FileNode] {
            var nodes: [FileNode] = []
            
            // Create directories with files
            for dirIndex in 0..<dirCount {
                var dirFiles: [FileNode] = []
                
                for fileIndex in 0..<fileCount {
                    dirFiles.append(FileNode.file(name: "file\(fileIndex).txt", 
                                                content: "content \(fileIndex) in dir \(dirIndex)"))
                }
                
                // Add some symbolic links
                if fileCount > 0 {
                    dirFiles.append(FileNode.symbolicLink(name: "link_to_first.link", 
                                                        target: "file0.txt"))
                }
                
                nodes.append(FileNode.directory(name: "dir\(dirIndex)", sub: dirFiles))
            }
            
            return nodes
        }
    }
}

final class RmTrashTests: CWDRestoringTestCase {

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

    func testInteractiveModeOnce() {

        let (fileManager, url) = FileManager.createTempDirectory()
        defer { try? fileManager.removeItem(at: url) }

        let mockFiles: [FileNode] = [
            .file(name: "test1.txt", content: "test1 content"),
            .directory(name: "dir1", sub: [])
        ]

        fileManager.createFileStructure(nodes: mockFiles, at: url)

        // Test with no answer (user declines once-prompt - this is a normal cancellation,
        // not a failure, so rm and rmtrash both exit 0).
        let noTrash = makeTrash(
            interactiveMode: .once,
            force: false,
            recursive: true,
            fileManager: fileManager,
            question: StaticAnswer(value: false)
        )
        XCTAssertTrue(noTrash.removeMultiple(paths: ["./test1.txt", "./dir1"]))
        assertFileStructure(fileManager, at: url, expectedFiles: mockFiles)

        // Test with yes answer
        let yesTrash = makeTrash(
            interactiveMode: .once,
            force: false,
            recursive: true,
            fileManager: fileManager,
            question: StaticAnswer(value: true)
        )
        XCTAssertTrue(yesTrash.removeMultiple(paths: ["./test1.txt", "./dir1"]))
        XCTAssertTrue(fileManager.isEmptyDirectory(url))
        assertFileStructure(fileManager, at: url, expectedFiles: [])
    }

    func testInteractiveModeAlways() {

        let (fileManager, url) = FileManager.createTempDirectory()
        defer { try? fileManager.removeItem(at: url) }

        let mockFiles: [FileNode] = [
            .file(name: "test1.txt", content: "test1 content"),
            .file(name: "test2.txt", content: "test2 content")
        ]

        fileManager.createFileStructure(nodes: mockFiles, at: url)

        // Test with no answer
        let noTrash = makeTrash(
            interactiveMode: .always,
            force: false,
            fileManager: fileManager,
            question: StaticAnswer(value: false)
        )
        XCTAssertTrue(noTrash.removeMultiple(paths: ["./test1.txt", "./test2.txt"]))
        assertFileStructure(fileManager, at: url, expectedFiles: mockFiles)

        // Test with yes answer
        let yesTrash = makeTrash(
            interactiveMode: .always,
            force: false,
            fileManager: fileManager,
            question: StaticAnswer(value: true)
        )
        XCTAssertTrue(yesTrash.removeMultiple(paths: ["./test1.txt", "./test2.txt"]))
        assertFileStructure(fileManager, at: url, expectedFiles: [])
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

    func testRemoveSymlink() {

        let (fileManager, url) = FileManager.createTempDirectory()
        defer { try? fileManager.removeItem(at: url) }

        let trash = makeTrash(force: false, recursive: true, emptyDirs: true, fileManager: fileManager)

        let file = url.appending(path: "no_such_file")
        let link = url.appending(path: "sym.link")

        XCTAssertNil(try fileManager.fileType(file))
        XCTAssertNil(try fileManager.fileType(link))
        XCTAssertNoThrow(try fileManager.createSymbolicLink(at: link, withDestinationURL: file))

        fileManager.subpaths(atPath: ".") { link in
            XCTAssertEqual(link, "./sym.link")
            return true
        }

        if let subs = try? fileManager.contentsOfDirectory(atPath: url.relativePath), let sub = subs.first {
            XCTAssertEqual(sub, "sym.link")
        }

        XCTAssertEqual(try fileManager.fileType(link), .typeSymbolicLink)
        XCTAssertTrue(trash.removeMultiple(paths: ["sym.link"]))
        XCTAssertNil(try fileManager.fileType(link))
    }
    
    func testRemoveHardLink() {
        let (fileManager, url) = FileManager.createTempDirectory()
        defer { try? fileManager.removeItem(at: url) }
        
        let trash = makeTrash(force: false, recursive: true, fileManager: fileManager)
        
        // Create original file
        let originalFile = url.appendingPathComponent("original.txt")
        let testContent = "test content".data(using: .utf8)!
        fileManager.createFile(atPath: originalFile.path, contents: testContent, attributes: nil)
        
        // Create hard link
        let hardLink = url.appendingPathComponent("hardlink.txt")
        XCTAssertNoThrow(try fileManager.linkItem(at: originalFile, to: hardLink))
        
        // Both should exist and be regular files
        XCTAssertEqual(try fileManager.fileType(originalFile), .typeRegular)
        XCTAssertEqual(try fileManager.fileType(hardLink), .typeRegular)
        
        // Both should have the same content
        XCTAssertEqual(try? Data(contentsOf: originalFile), testContent)
        XCTAssertEqual(try? Data(contentsOf: hardLink), testContent)
        
        // Remove the hard link (should behave like rm - only remove one reference)
        XCTAssertTrue(trash.removeMultiple(paths: ["hardlink.txt"]))
        
        // Hard link should be gone, but original file should still exist
        XCTAssertNil(try fileManager.fileType(hardLink))
        XCTAssertEqual(try fileManager.fileType(originalFile), .typeRegular)
        XCTAssertEqual(try? Data(contentsOf: originalFile), testContent)
    }
    
    func testRemoveSymlinkToExistingFile() {
        let (fileManager, url) = FileManager.createTempDirectory()
        defer { try? fileManager.removeItem(at: url) }
        
        let trash = makeTrash(force: false, recursive: true, fileManager: fileManager)
        
        // Create target file
        let targetFile = url.appendingPathComponent("target.txt")
        let testContent = "target content".data(using: .utf8)!
        fileManager.createFile(atPath: targetFile.path, contents: testContent, attributes: nil)
        
        // Create symbolic link to existing file
        let symlink = url.appendingPathComponent("symlink.txt")
        XCTAssertNoThrow(try fileManager.createSymbolicLink(at: symlink, withDestinationURL: targetFile))
        
        // Verify types
        XCTAssertEqual(try fileManager.fileType(targetFile), .typeRegular)
        XCTAssertEqual(try fileManager.fileType(symlink), .typeSymbolicLink)
        
        // Remove symbolic link (should behave like rm - only remove the link, not the target)
        XCTAssertTrue(trash.removeMultiple(paths: ["symlink.txt"]))
        
        // Symbolic link should be gone, but target file should still exist
        XCTAssertNil(try fileManager.fileType(symlink))
        XCTAssertEqual(try fileManager.fileType(targetFile), .typeRegular)
        XCTAssertEqual(try? Data(contentsOf: targetFile), testContent)
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

        // Test removing multiple files together
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
        let trashNoForce = makeTrash(
            force: false,
            fileManager: fileManager
        )
        XCTAssertFalse(trashNoForce.removeMultiple(paths: ["./nonexistent.txt"]))

        // Test with force = true
        let trashForce = makeTrash(
            force: true,
            fileManager: fileManager
        )
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

    // MARK: - Interactive Directory Removal

    /// Building block for the interactive-removal specs below: a directory with
    /// three regular files, driven in `.always` mode answering "yes" to every
    /// prompt, using `RecordingFileManager` so failures can be injected
    /// deterministically without touching the real Trash.
    private func makeInteractiveDirScenario(
        failing: Set<String> = []
    ) -> (mock: RecordingFileManager, dirPath: String, cleanup: () -> Void) {
        let (real, url) = FileManager.createTempDirectory()
        real.createFileStructure(nodes: [
            .directory(name: "dir", sub: [
                .file(name: "a.txt", content: "a"),
                .file(name: "b.txt", content: "b"),
                .file(name: "c.txt", content: "c")
            ])
        ], at: url)
        let mock = RecordingFileManager()
        mock.failing = failing
        return (mock, url.appendingPathComponent("dir").path, { try? real.removeItem(at: url) })
    }

    /// Correctness: when every item is removable, the whole directory is trashed
    /// and the operation reports success.
    func testInteractiveDirectoryRemovesEverythingAndReportsSuccess() {
        let (mock, dirPath, cleanup) = makeInteractiveDirScenario()
        defer { cleanup() }

        let trash = makeTrash(interactiveMode: .always, force: false, recursive: true,
                              fileManager: mock, question: StaticAnswer(value: true))

        XCTAssertTrue(trash.removeMultiple(paths: [dirPath]))
        XCTAssertEqual(Set(mock.removed), ["a.txt", "b.txt", "c.txt", "dir"])
        XCTAssertNil(try mock.fileType(URL(fileURLWithPath: dirPath)))
    }

    /// Accuracy: if any item cannot be removed, the operation reports failure
    /// (exit status), instead of masking the error as success.
    func testInteractiveDirectoryReportsFailureWhenAnItemCannotBeRemoved() {
        let (mock, dirPath, cleanup) = makeInteractiveDirScenario(failing: ["b.txt"])
        defer { cleanup() }

        let trash = makeTrash(interactiveMode: .always, force: false, recursive: true,
                              fileManager: mock, question: StaticAnswer(value: true))

        XCTAssertFalse(trash.removeMultiple(paths: [dirPath]))
    }

    /// Completeness: a failure on one child must not abort the walk. Every sibling
    /// is still visited and the removable ones are removed. The failing file
    /// ("a.txt") sorts first, so a premature stop would leave b/c untouched.
    func testInteractiveDirectoryVisitsEveryChildEvenWhenOneFails() {
        let (mock, dirPath, cleanup) = makeInteractiveDirScenario(failing: ["a.txt"])
        defer { cleanup() }

        let trash = makeTrash(interactiveMode: .always, force: false, recursive: true,
                              fileManager: mock, question: StaticAnswer(value: true))

        _ = trash.removeMultiple(paths: [dirPath])

        XCTAssertEqual(Set(mock.attempted), ["a.txt", "b.txt", "c.txt"])
        XCTAssertEqual(Set(mock.removed), ["b.txt", "c.txt"])
    }

    // MARK: - Interactive Once Threshold

    /// A directory containing `names` as regular files, plus a mock that removes
    /// without touching the real Trash.
    private func makeFilesScenario(_ names: [String]) -> (mock: RecordingFileManager, paths: [String], cleanup: () -> Void) {
        let (real, url) = FileManager.createTempDirectory()
        for name in names {
            real.createFile(atPath: url.appendingPathComponent(name).path, contents: Data(), attributes: nil)
        }
        let mock = RecordingFileManager()
        let paths = names.map { url.appendingPathComponent($0).path }
        return (mock, paths, { try? real.removeItem(at: url) })
    }

    /// `-I` is the light-touch guard: three or fewer plain files are removed
    /// without any confirmation.
    func testInteractiveOnceDoesNotPromptForThreeOrFewerFiles() {
        let (mock, paths, cleanup) = makeFilesScenario(["a.txt", "b.txt", "c.txt"])
        defer { cleanup() }

        let q = RecordingQuestion(answer: true)
        let trash = makeTrash(interactiveMode: .once, force: false, fileManager: mock, question: q)

        XCTAssertTrue(trash.removeMultiple(paths: paths))
        XCTAssertTrue(q.asked.isEmpty)
        XCTAssertEqual(Set(mock.removed), ["a.txt", "b.txt", "c.txt"])
    }

    /// More than three files trips a single confirmation; declining it cancels
    /// the whole batch (a normal, successful cancellation).
    func testInteractiveOncePromptsOnceForMoreThanThreeFiles() {
        let (mock, paths, cleanup) = makeFilesScenario(["a.txt", "b.txt", "c.txt", "d.txt"])
        defer { cleanup() }

        let q = RecordingQuestion(answer: false)
        let trash = makeTrash(interactiveMode: .once, force: false, fileManager: mock, question: q)

        XCTAssertTrue(trash.removeMultiple(paths: paths))
        XCTAssertEqual(q.asked.count, 1)
        XCTAssertTrue(mock.removed.isEmpty)
    }

    // MARK: - Preserve Root

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

    // MARK: - Protected Operands Tests

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

    // MARK: - Enhanced Test Infrastructure Tests
    
    func testSymbolicLinkChain() {
        let (fileManager, url) = FileManager.createTempDirectory()
        defer { try? fileManager.removeItem(at: url) }
        
        // Test symbolic link chain generation
        let linkChain = FileSystemTestUtilities.SymbolicLinkGenerator.generateLinkChain(length: 3)
        fileManager.createFileStructure(nodes: linkChain, at: url)
        
        let trash = makeTrash(force: true, recursive: true, fileManager: fileManager)
        
        // Remove the final link in the chain
        XCTAssertTrue(trash.removeMultiple(paths: ["./link3.link"]))
        
        // Verify the chain is broken but other links remain
        XCTAssertNil(try fileManager.fileType(url.appendingPathComponent("link3.link")))
        XCTAssertEqual(try fileManager.fileType(url.appendingPathComponent("link2.link")), .typeSymbolicLink)
        XCTAssertEqual(try fileManager.fileType(url.appendingPathComponent("target.txt")), .typeRegular)
    }
    
    func testCircularSymbolicLinks() {
        let (fileManager, url) = FileManager.createTempDirectory()
        defer { try? fileManager.removeItem(at: url) }
        
        // Test circular symbolic links
        let circularLinks = FileSystemTestUtilities.SymbolicLinkGenerator.generateCircularLinks()
        fileManager.createFileStructure(nodes: circularLinks, at: url)
        
        let trash = makeTrash(force: true, fileManager: fileManager)
        
        // Should be able to remove circular links
        XCTAssertTrue(trash.removeMultiple(paths: ["./link_a.link"]))
        XCTAssertNil(try fileManager.fileType(url.appendingPathComponent("link_a.link")))
        XCTAssertEqual(try fileManager.fileType(url.appendingPathComponent("link_b.link")), .typeSymbolicLink)
    }
    
    func testBrokenSymbolicLinks() {
        let (fileManager, url) = FileManager.createTempDirectory()
        defer { try? fileManager.removeItem(at: url) }
        
        // Test broken symbolic links
        let brokenLinks = FileSystemTestUtilities.SymbolicLinkGenerator.generateBrokenLinks()
        fileManager.createFileStructure(nodes: brokenLinks, at: url)
        
        let trash = makeTrash(force: true, fileManager: fileManager)
        
        // Should be able to remove broken symbolic links
        XCTAssertTrue(trash.removeMultiple(paths: ["./broken1.link", "./broken2.link", "./broken3.link"]))
        
        // Verify all broken links are removed
        XCTAssertNil(try fileManager.fileType(url.appendingPathComponent("broken1.link")))
        XCTAssertNil(try fileManager.fileType(url.appendingPathComponent("broken2.link")))
        XCTAssertNil(try fileManager.fileType(url.appendingPathComponent("broken3.link")))
    }
    
    func testMixedLinkScenario() {
        let (fileManager, url) = FileManager.createTempDirectory()
        defer { try? fileManager.removeItem(at: url) }
        
        // Test mixed symbolic and hard links
        let mixedLinks = FileSystemTestUtilities.SymbolicLinkGenerator.generateMixedLinkScenario()
        fileManager.createFileStructure(nodes: mixedLinks, at: url)
        
        let trash = makeTrash(force: true, recursive: true, fileManager: fileManager)
        
        // Remove a hard link - original should remain
        XCTAssertTrue(trash.removeMultiple(paths: ["./hard1.txt"]))
        XCTAssertNil(try fileManager.fileType(url.appendingPathComponent("hard1.txt")))
        XCTAssertEqual(try fileManager.fileType(url.appendingPathComponent("original.txt")), .typeRegular)
        XCTAssertEqual(try fileManager.fileType(url.appendingPathComponent("hard2.txt")), .typeRegular)
        
        // Remove a symbolic link - target should remain
        XCTAssertTrue(trash.removeMultiple(paths: ["./sym_to_original.link"]))
        XCTAssertNil(try fileManager.fileType(url.appendingPathComponent("sym_to_original.link")))
        XCTAssertEqual(try fileManager.fileType(url.appendingPathComponent("original.txt")), .typeRegular)
    }
    
    func testAbsoluteRelativeLinks() {
        let (fileManager, url) = FileManager.createTempDirectory()
        defer { try? fileManager.removeItem(at: url) }
        
        // Test absolute vs relative symbolic links
        let absRelLinks = FileSystemTestUtilities.SymbolicLinkGenerator.generateAbsoluteRelativeLinks(baseURL: url)
        fileManager.createFileStructure(nodes: absRelLinks, at: url)
        
        let trash = makeTrash(force: true, recursive: true, fileManager: fileManager)
        
        // Both relative and absolute links should work
        XCTAssertEqual(try fileManager.fileType(url.appendingPathComponent("relative.link")), .typeSymbolicLink)
        XCTAssertEqual(try fileManager.fileType(url.appendingPathComponent("absolute.link")), .typeSymbolicLink)
        
        // Remove the target - links become broken but should still be removable
        XCTAssertTrue(trash.removeMultiple(paths: ["./target.txt"]))
        XCTAssertTrue(trash.removeMultiple(paths: ["./relative.link", "./absolute.link"]))
    }
    
    func testVolumeSimulation() throws {
        // Sanity-check the mock's volume bookkeeping: a URL on a different volume
        // than the base should be reported as cross-mount; a URL on the same volume
        // as the base (even if the *CWD* is on yet another volume) should not.
        // This protects against the regression of comparing against CWD instead of
        // the command-line argument.
        let mockFM = FileSystemTestUtilities.VolumeSimulator.MockVolumeFileManager()
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

        let mockFM = FileSystemTestUtilities.VolumeSimulator.MockVolumeFileManager()
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
        let mockFM = FileSystemTestUtilities.VolumeSimulator.MockVolumeFileManager()
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
        let mockFM = FileSystemTestUtilities.VolumeSimulator.MockVolumeFileManager()
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
    
    func testDeepHierarchyGeneration() {
        let (fileManager, url) = FileManager.createTempDirectory()
        defer { try? fileManager.removeItem(at: url) }
        
        // Test deep hierarchy generation
        let deepHierarchy = FileSystemTestUtilities.ScenarioGenerator.generateDeepHierarchy(depth: 5, filesPerLevel: 2)
        fileManager.createFileStructure(node: deepHierarchy, at: url)
        
        let trash = makeTrash(force: true, recursive: true, fileManager: fileManager)
        
        // Should be able to remove the entire deep hierarchy
        XCTAssertTrue(trash.removeMultiple(paths: ["./root"]))
        XCTAssertNil(try fileManager.fileType(url.appendingPathComponent("root")))
    }
    
    func testPermissionScenario() {
        let (fileManager, url) = FileManager.createTempDirectory()
        defer { try? fileManager.removeItem(at: url) }
        
        // Test permission-like scenarios
        let permissionNodes = FileSystemTestUtilities.ScenarioGenerator.generatePermissionScenario()
        fileManager.createFileStructure(nodes: permissionNodes, at: url)
        
        let trash = makeTrash(force: true, recursive: true, emptyDirs: true, fileManager: fileManager)
        
        // Should handle empty directories
        XCTAssertTrue(trash.removeMultiple(paths: ["./empty_dir"]))
        XCTAssertNil(try fileManager.fileType(url.appendingPathComponent("empty_dir")))
        
        // Should handle nested empty directories
        XCTAssertTrue(trash.removeMultiple(paths: ["./nested_empty"]))
        XCTAssertNil(try fileManager.fileType(url.appendingPathComponent("nested_empty")))
        
        // Should handle broken symbolic links
        XCTAssertTrue(trash.removeMultiple(paths: ["./mixed_content"]))
        XCTAssertNil(try fileManager.fileType(url.appendingPathComponent("mixed_content")))
    }
    
    func testLargeFileSystemGeneration() {
        let (fileManager, url) = FileManager.createTempDirectory()
        defer { try? fileManager.removeItem(at: url) }
        
        // Test large file system generation (smaller scale for unit test)
        let largeFS = FileSystemTestUtilities.ScenarioGenerator.generateLargeFileSystem(dirCount: 3, fileCount: 5)
        fileManager.createFileStructure(nodes: largeFS, at: url)
        
        let trash = makeTrash(force: true, recursive: true, fileManager: fileManager)
        
        // Should handle multiple directories with files
        XCTAssertTrue(trash.removeMultiple(paths: ["./dir0", "./dir1"]))
        XCTAssertNil(try fileManager.fileType(url.appendingPathComponent("dir0")))
        XCTAssertNil(try fileManager.fileType(url.appendingPathComponent("dir1")))
        XCTAssertEqual(try fileManager.fileType(url.appendingPathComponent("dir2")), .typeDirectory)
    }
}

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
    
    func testVolumeInfoExtraction() throws {
        let (fileManager, url) = FileManager.createTempDirectory()
        defer { try? fileManager.removeItem(at: url) }
        
        let resourceValues = try url.resourceValues(forKeys: [.volumeURLKey, .volumeUUIDStringKey, .volumeNameKey])
        
        // Basic volume info should be available
        XCTAssertNotNil(resourceValues.volume)
        XCTAssertNotNil(resourceValues.volumeName)
    }
}

final class CommandParsingTests: XCTestCase {

    private func config(_ args: [String]) throws -> Trash.Config {
        try Command.parse(args).parseArgs()
    }

    func testMissingOperandThrows() {
        XCTAssertThrowsError(try config([]))
    }

    func testForceWithNoOperandsSucceedsQuietly() throws {
        let c = try config(["-f"])
        XCTAssertTrue(c.force)
        XCTAssertEqual(c.interactiveMode, .never)
    }

    func testInteractiveFlagsMapToModes() throws {
        XCTAssertEqual(try config(["x"]).interactiveMode, .never)
        XCTAssertEqual(try config(["-i", "x"]).interactiveMode, .always)
        XCTAssertEqual(try config(["-I", "x"]).interactiveMode, .once)
        XCTAssertEqual(try config(["--interactive=once", "x"]).interactiveMode, .once)
        XCTAssertEqual(try config(["--interactive=always", "x"]).interactiveMode, .always)
    }

    func testForceOverridesInteractive() throws {
        // -f silences prompts even when combined with -i.
        XCTAssertEqual(try config(["-f", "-i", "x"]).interactiveMode, .never)
    }

    func testInvalidInteractiveValueIsRejected() {
        XCTAssertThrowsError(try Command.parse(["--interactive=nope", "x"]))
    }

    func testBooleanFlagsMapToConfig() throws {
        let c = try config(["-r", "-d", "-x", "x"])
        XCTAssertTrue(c.recursive)
        XCTAssertTrue(c.emptyDirs)
        XCTAssertTrue(c.oneFileSystem)
        XCTAssertTrue(c.preserveRoot) // on by default
        XCTAssertFalse(try config(["--no-preserve-root", "x"]).preserveRoot)
    }
}

func makeTrash(
    interactiveMode: Trash.Config.InteractiveMode = .never,
    force: Bool = true,
    recursive: Bool = false,
    emptyDirs: Bool = false,
    preserveRoot: Bool = true,
    oneFileSystem: Bool = false,
    verbose: Bool = false,
    fileManager: FileManagerType = TestFileManager(),
    question: Question =  StaticAnswer(value: true)
) -> Trash {
    let config = Trash.Config(
        interactiveMode: interactiveMode,
        force: force,
        recursive: recursive,
        emptyDirs: emptyDirs,
        preserveRoot: preserveRoot,
        oneFileSystem: oneFileSystem,
        verbose: verbose
    )
    return Trash(
        config: config,
        question: question,
        fileManager: fileManager
    )
}

func assertFileStructure(_ fileManager: FileManager, at url: URL, expectedFiles: [FileNode], file: StaticString = #file, line: UInt = #line) {
    guard let node = fileManager.currentFileStructure(at: url) else {
        XCTFail("Failed to read file structure at \(url)", file: file, line: line)
        return
    }
    switch node {
    case .directory(_, let sub):
        XCTAssertTrue(sub == expectedFiles, file: file, line: line)
    case .file(_, _):
        XCTFail("Expected directory, found file", file: file, line: line)
    case .symbolicLink(_, _):
        XCTFail("Expected directory, found symbolic link", file: file, line: line)
    case .hardLink(_, _):
        XCTFail("Expected directory, found hard link", file: file, line: line)
    }
}
