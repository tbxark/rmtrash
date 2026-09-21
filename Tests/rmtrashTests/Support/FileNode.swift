import XCTest
@testable import rmtrash

/// Declarative description of a directory tree, used both to create fixtures
/// and to assert on the resulting on-disk state.
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

extension FileManager {
    /// Reads the tree back as `FileNode`s. Hard links are indistinguishable from
    /// regular files on disk, so they come back as `.file`, never `.hardLink`;
    /// don't put `.hardLink` in an expected structure.
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
