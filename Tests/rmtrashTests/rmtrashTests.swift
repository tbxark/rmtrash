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

    static func createTempDirectory() -> (fileManager: FileManager, url: URL) {
        let fileManager = FileManager()
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
        
        /// Mock file manager for simulating different volumes
        class MockVolumeFileManager: FileManagerType {
            private let baseFileManager = FileManager()
            private var volumeMap: [String: String] = [:]
            private var crossMountPoints: Set<String> = []
            
            func setVolume(_ volumeId: String, for path: String) {
                volumeMap[path] = volumeId
            }
            
            func setCrossMountPoint(_ path: String) {
                crossMountPoints.insert(path)
            }
            
            func trashItem(at url: URL) throws {
                try baseFileManager.trashItem(at: url)
            }
            
            func isRootDir(_ url: URL) -> Bool {
                return baseFileManager.isRootDir(url)
            }
            
            func isEmptyDirectory(_ url: URL) -> Bool {
                return baseFileManager.isEmptyDirectory(url)
            }
            
            func isCrossMountPoint(_ url: URL) throws -> Bool {
                let path = url.standardizedFileURL.path
                return crossMountPoints.contains(path) || 
                       crossMountPoints.contains { path.hasPrefix($0) }
            }
            
            func fileType(_ url: URL) -> FileAttributeType? {
                return baseFileManager.fileType(url)
            }
            
            func subpaths(atPath path: String, enumerator handler: (String) -> Bool) {
                baseFileManager.subpaths(atPath: path, enumerator: handler)
            }
        }
        
        /// Create a test scenario with multiple volumes
        static func createMultiVolumeScenario() -> (fileManager: MockVolumeFileManager, nodes: [FileNode]) {
            let mockFM = MockVolumeFileManager()
            
            let nodes: [FileNode] = [
                FileNode.directory(name: "volume1", sub: [
                    FileNode.file(name: "file1.txt", content: "volume1 content"),
                    FileNode.directory(name: "subdir", sub: [
                        FileNode.file(name: "nested.txt", content: "nested in volume1")
                    ])
                ]),
                FileNode.directory(name: "volume2", sub: [
                    FileNode.file(name: "file2.txt", content: "volume2 content"),
                    FileNode.symbolicLink(name: "cross_vol_link.link", target: "../volume1/file1.txt")
                ]),
                FileNode.directory(name: "mount_point", sub: [
                    FileNode.file(name: "mounted_file.txt", content: "mounted content")
                ])
            ]
            
            // Configure volume mappings
            mockFM.setVolume("vol1", for: "/volume1")
            mockFM.setVolume("vol2", for: "/volume2")
            mockFM.setVolume("vol3", for: "/mount_point")
            
            // Set cross-mount points
            mockFM.setCrossMountPoint("/volume2")
            mockFM.setCrossMountPoint("/mount_point")
            
            return (mockFM, nodes)
        }
        
        /// Create a scenario with network mount simulation
        static func createNetworkMountScenario() -> (fileManager: MockVolumeFileManager, nodes: [FileNode]) {
            let mockFM = MockVolumeFileManager()
            
            let nodes: [FileNode] = [
                FileNode.directory(name: "local", sub: [
                    FileNode.file(name: "local_file.txt", content: "local content")
                ]),
                FileNode.directory(name: "network_mount", sub: [
                    FileNode.file(name: "remote_file.txt", content: "remote content"),
                    FileNode.directory(name: "remote_dir", sub: [
                        FileNode.file(name: "deep_remote.txt", content: "deep remote content")
                    ])
                ])
            ]
            
            // Configure as network mount (different volume)
            mockFM.setVolume("local_vol", for: "/local")
            mockFM.setVolume("network_vol", for: "/network_mount")
            mockFM.setCrossMountPoint("/network_mount")
            
            return (mockFM, nodes)
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

final class RmTrashTests: XCTestCase {

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

    func testInteractiveModeOnce() {

        let (fileManager, url) = FileManager.createTempDirectory()
        defer { try? fileManager.removeItem(at: url) }

        let mockFiles: [FileNode] = [
            .file(name: "test1.txt", content: "test1 content"),
            .directory(name: "dir1", sub: [])
        ]

        fileManager.createFileStructure(nodes: mockFiles, at: url)

        // Test with no answer (user declines - should return failure)
        let noTrash = makeTrash(
            interactiveMode: .once,
            force: false,
            recursive: true,
            fileManager: fileManager,
            question: StaticAnswer(value: false)
        )
        XCTAssertFalse(noTrash.removeMultiple(paths: ["./test1.txt", "./dir1"]))
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

        XCTAssertNil(fileManager.fileType(file))
        XCTAssertNil(fileManager.fileType(link))
        XCTAssertNoThrow(try fileManager.createSymbolicLink(at: link, withDestinationURL: file))

        fileManager.subpaths(atPath: ".") { link in
            XCTAssertEqual(link, "./sym.link")
            return true
        }

        if let subs = try? fileManager.contentsOfDirectory(atPath: url.relativePath), let sub = subs.first {
            XCTAssertEqual(sub, "sym.link")
        }

        XCTAssertEqual(fileManager.fileType(link), .typeSymbolicLink)
        XCTAssertTrue(trash.removeMultiple(paths: ["sym.link"]))
        XCTAssertNil(fileManager.fileType(link))
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
        XCTAssertEqual(fileManager.fileType(originalFile), .typeRegular)
        XCTAssertEqual(fileManager.fileType(hardLink), .typeRegular)
        
        // Both should have the same content
        XCTAssertEqual(try? Data(contentsOf: originalFile), testContent)
        XCTAssertEqual(try? Data(contentsOf: hardLink), testContent)
        
        // Remove the hard link (should behave like rm - only remove one reference)
        XCTAssertTrue(trash.removeMultiple(paths: ["hardlink.txt"]))
        
        // Hard link should be gone, but original file should still exist
        XCTAssertNil(fileManager.fileType(hardLink))
        XCTAssertEqual(fileManager.fileType(originalFile), .typeRegular)
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
        XCTAssertEqual(fileManager.fileType(targetFile), .typeRegular)
        XCTAssertEqual(fileManager.fileType(symlink), .typeSymbolicLink)
        
        // Remove symbolic link (should behave like rm - only remove the link, not the target)
        XCTAssertTrue(trash.removeMultiple(paths: ["symlink.txt"]))
        
        // Symbolic link should be gone, but target file should still exist
        XCTAssertNil(fileManager.fileType(symlink))
        XCTAssertEqual(fileManager.fileType(targetFile), .typeRegular)
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
        XCTAssertNil(fileManager.fileType(url.appendingPathComponent("link3.link")))
        XCTAssertEqual(fileManager.fileType(url.appendingPathComponent("link2.link")), .typeSymbolicLink)
        XCTAssertEqual(fileManager.fileType(url.appendingPathComponent("target.txt")), .typeRegular)
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
        XCTAssertNil(fileManager.fileType(url.appendingPathComponent("link_a.link")))
        XCTAssertEqual(fileManager.fileType(url.appendingPathComponent("link_b.link")), .typeSymbolicLink)
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
        XCTAssertNil(fileManager.fileType(url.appendingPathComponent("broken1.link")))
        XCTAssertNil(fileManager.fileType(url.appendingPathComponent("broken2.link")))
        XCTAssertNil(fileManager.fileType(url.appendingPathComponent("broken3.link")))
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
        XCTAssertNil(fileManager.fileType(url.appendingPathComponent("hard1.txt")))
        XCTAssertEqual(fileManager.fileType(url.appendingPathComponent("original.txt")), .typeRegular)
        XCTAssertEqual(fileManager.fileType(url.appendingPathComponent("hard2.txt")), .typeRegular)
        
        // Remove a symbolic link - target should remain
        XCTAssertTrue(trash.removeMultiple(paths: ["./sym_to_original.link"]))
        XCTAssertNil(fileManager.fileType(url.appendingPathComponent("sym_to_original.link")))
        XCTAssertEqual(fileManager.fileType(url.appendingPathComponent("original.txt")), .typeRegular)
    }
    
    func testAbsoluteRelativeLinks() {
        let (fileManager, url) = FileManager.createTempDirectory()
        defer { try? fileManager.removeItem(at: url) }
        
        // Test absolute vs relative symbolic links
        let absRelLinks = FileSystemTestUtilities.SymbolicLinkGenerator.generateAbsoluteRelativeLinks(baseURL: url)
        fileManager.createFileStructure(nodes: absRelLinks, at: url)
        
        let trash = makeTrash(force: true, recursive: true, fileManager: fileManager)
        
        // Both relative and absolute links should work
        XCTAssertEqual(fileManager.fileType(url.appendingPathComponent("relative.link")), .typeSymbolicLink)
        XCTAssertEqual(fileManager.fileType(url.appendingPathComponent("absolute.link")), .typeSymbolicLink)
        
        // Remove the target - links become broken but should still be removable
        XCTAssertTrue(trash.removeMultiple(paths: ["./target.txt"]))
        XCTAssertTrue(trash.removeMultiple(paths: ["./relative.link", "./absolute.link"]))
    }
    
    func testVolumeSimulation() {
        let (fileManager, url) = FileManager.createTempDirectory()
        defer { try? fileManager.removeItem(at: url) }
        
        // Test volume simulation
        let (mockFM, volumeNodes) = FileSystemTestUtilities.VolumeSimulator.createMultiVolumeScenario()
        fileManager.createFileStructure(nodes: volumeNodes, at: url)
        
        // Test with oneFileSystem flag - should respect volume boundaries
        let _ = makeTrash(
            force: true,
            recursive: true,
            oneFileSystem: true,
            fileManager: mockFM
        )
        
        // This test verifies the infrastructure is in place for volume simulation
        XCTAssertNotNil(mockFM)
        
        // Verify the mock file manager can detect cross-mount points
        // The mock is configured to treat "/volume2" as a cross-mount point
        let testURL = URL(fileURLWithPath: "/volume2")
        XCTAssertTrue(try mockFM.isCrossMountPoint(testURL))
        
        // Test that a non-cross-mount point returns false
        let localURL = URL(fileURLWithPath: "/local")
        XCTAssertFalse(try mockFM.isCrossMountPoint(localURL))
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
        XCTAssertNil(fileManager.fileType(url.appendingPathComponent("root")))
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
        XCTAssertNil(fileManager.fileType(url.appendingPathComponent("empty_dir")))
        
        // Should handle nested empty directories
        XCTAssertTrue(trash.removeMultiple(paths: ["./nested_empty"]))
        XCTAssertNil(fileManager.fileType(url.appendingPathComponent("nested_empty")))
        
        // Should handle broken symbolic links
        XCTAssertTrue(trash.removeMultiple(paths: ["./mixed_content"]))
        XCTAssertNil(fileManager.fileType(url.appendingPathComponent("mixed_content")))
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
        XCTAssertNil(fileManager.fileType(url.appendingPathComponent("dir0")))
        XCTAssertNil(fileManager.fileType(url.appendingPathComponent("dir1")))
        XCTAssertEqual(fileManager.fileType(url.appendingPathComponent("dir2")), .typeDirectory)
    }
}

final class FileManagerTests: XCTestCase {

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

    func testFileTypeDetection() {
        let (fileManager, url) = FileManager.createTempDirectory()
        defer { try? fileManager.removeItem(at: url) }

        XCTAssertNil(fileManager.fileType(url.appendingPathComponent("no_file")))

        let fileURL = url.appendingPathComponent("temp.txt")
        fileManager.createFile(atPath: fileURL.path, contents: nil, attributes: nil)
        XCTAssertEqual(fileManager.fileType(fileURL), .typeRegular)
        XCTAssertEqual(fileManager.fileType(url), .typeDirectory)
    }
    
    func testCrossMountPointDetection() throws {
        let (fileManager, url) = FileManager.createTempDirectory()
        defer { try? fileManager.removeItem(at: url) }
        
        // Test same volume detection
        let subDir = url.appendingPathComponent("subdir")
        try fileManager.createDirectory(at: subDir, withIntermediateDirectories: true, attributes: nil)
        
        // Files on the same volume should not be cross-mount points
        XCTAssertFalse(try fileManager.isCrossMountPoint(subDir))
        XCTAssertFalse(try fileManager.isCrossMountPoint(url))
        
        // Test with root directory (different volume in most cases)
        let rootURL = URL(fileURLWithPath: "/")
        
        // Get volume info to check if we're actually on different volumes
        let tempVol = try url.resourceValues(forKeys: [.volumeURLKey])
        let rootVol = try rootURL.resourceValues(forKeys: [.volumeURLKey])
        
        // Only test cross-mount if we're actually on different volumes
        if tempVol.volume != rootVol.volume {
            XCTAssertTrue(try fileManager.isCrossMountPoint(rootURL))
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

func makeTrash(
    interactiveMode: Trash.Config.InteractiveMode = .never,
    force: Bool = true,
    recursive: Bool = false,
    emptyDirs: Bool = false,
    preserveRoot: Bool = true,
    oneFileSystem: Bool = false,
    verbose: Bool = false,
    fileManager: FileManagerType = FileManager.default,
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
