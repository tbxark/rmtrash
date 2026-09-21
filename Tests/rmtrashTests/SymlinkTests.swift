import XCTest
@testable import rmtrash

/// Symbolic and hard links: rmtrash never follows a link, so removing one
/// touches only the link itself.
final class SymlinkTests: CWDRestoringTestCase {

    func testRemoveDanglingSymlink() {
        let (fileManager, url) = FileManager.createTempDirectory()
        defer { try? fileManager.removeItem(at: url) }

        let trash = makeTrash(force: false, recursive: true, emptyDirs: true, fileManager: fileManager)

        let file = url.appendingPathComponent("no_such_file")
        let link = url.appendingPathComponent("sym.link")

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

        let originalFile = url.appendingPathComponent("original.txt")
        let testContent = "test content".data(using: .utf8)!
        fileManager.createFile(atPath: originalFile.path, contents: testContent, attributes: nil)

        let hardLink = url.appendingPathComponent("hardlink.txt")
        XCTAssertNoThrow(try fileManager.linkItem(at: originalFile, to: hardLink))

        XCTAssertEqual(try fileManager.fileType(originalFile), .typeRegular)
        XCTAssertEqual(try fileManager.fileType(hardLink), .typeRegular)
        XCTAssertEqual(try? Data(contentsOf: originalFile), testContent)
        XCTAssertEqual(try? Data(contentsOf: hardLink), testContent)

        // Remove the hard link (should behave like rm - only remove one reference)
        XCTAssertTrue(trash.removeMultiple(paths: ["hardlink.txt"]))

        XCTAssertNil(try fileManager.fileType(hardLink))
        XCTAssertEqual(try fileManager.fileType(originalFile), .typeRegular)
        XCTAssertEqual(try? Data(contentsOf: originalFile), testContent)
    }

    func testRemoveSymlinkToExistingFile() {
        let (fileManager, url) = FileManager.createTempDirectory()
        defer { try? fileManager.removeItem(at: url) }

        let trash = makeTrash(force: false, recursive: true, fileManager: fileManager)

        let targetFile = url.appendingPathComponent("target.txt")
        let testContent = "target content".data(using: .utf8)!
        fileManager.createFile(atPath: targetFile.path, contents: testContent, attributes: nil)

        let symlink = url.appendingPathComponent("symlink.txt")
        XCTAssertNoThrow(try fileManager.createSymbolicLink(at: symlink, withDestinationURL: targetFile))

        XCTAssertEqual(try fileManager.fileType(targetFile), .typeRegular)
        XCTAssertEqual(try fileManager.fileType(symlink), .typeSymbolicLink)

        // Remove symbolic link (should behave like rm - only remove the link, not the target)
        XCTAssertTrue(trash.removeMultiple(paths: ["symlink.txt"]))

        XCTAssertNil(try fileManager.fileType(symlink))
        XCTAssertEqual(try fileManager.fileType(targetFile), .typeRegular)
        XCTAssertEqual(try? Data(contentsOf: targetFile), testContent)
    }

    // MARK: - Links to directories

    /// A trailing slash on a symlink to a directory (what shell tab-completion
    /// produces) must not cause the link target to be trashed. BSD `rm -r link/`
    /// removes the target's contents; rmtrash removes only the link.
    func testTrailingSlashOnSymlinkToDirectoryRemovesOnlyTheLink() throws {
        let (fileManager, url) = FileManager.createTempDirectory()
        defer { try? fileManager.removeItem(at: url) }
        fileManager.createFileStructure(nodes: [
            .directory(name: "realdir", sub: [.file(name: "keep.txt", content: "k")]),
            .symbolicLink(name: "link", target: "realdir")
        ], at: url)

        let trash = makeTrash(force: false, recursive: true, fileManager: fileManager)
        XCTAssertTrue(trash.removeMultiple(paths: [url.appendingPathComponent("link").path + "/"]))

        XCTAssertNil(try fileManager.fileType(url.appendingPathComponent("link")))
        XCTAssertEqual(try fileManager.fileType(url.appendingPathComponent("realdir/keep.txt")), .typeRegular)
    }

    /// `-d` on a symlink to a (non-empty) directory removes the link, like
    /// `rm -d link`; the directory check never applies to the link itself.
    func testEmptyDirsOnSymlinkToDirectoryRemovesOnlyTheLink() throws {
        let (fileManager, url) = FileManager.createTempDirectory()
        defer { try? fileManager.removeItem(at: url) }
        fileManager.createFileStructure(nodes: [
            .directory(name: "realdir", sub: [.file(name: "keep.txt", content: "k")]),
            .symbolicLink(name: "link", target: "realdir")
        ], at: url)

        let trash = makeTrash(force: false, emptyDirs: true, fileManager: fileManager)
        XCTAssertTrue(trash.removeMultiple(paths: [url.appendingPathComponent("link").path]))

        XCTAssertNil(try fileManager.fileType(url.appendingPathComponent("link")))
        XCTAssertEqual(try fileManager.fileType(url.appendingPathComponent("realdir/keep.txt")), .typeRegular)
    }

    // MARK: - Link topologies

    /// Removing the last link of a chain (link3 -> link2 -> link1 -> target)
    /// leaves the rest of the chain and the target intact.
    func testSymbolicLinkChain() {
        let (fileManager, url) = FileManager.createTempDirectory()
        defer { try? fileManager.removeItem(at: url) }
        fileManager.createFileStructure(nodes: [
            .file(name: "target.txt", content: "target content"),
            .symbolicLink(name: "link1.link", target: "target.txt"),
            .symbolicLink(name: "link2.link", target: "link1.link"),
            .symbolicLink(name: "link3.link", target: "link2.link")
        ], at: url)

        let trash = makeTrash(force: true, recursive: true, fileManager: fileManager)
        XCTAssertTrue(trash.removeMultiple(paths: ["./link3.link"]))

        XCTAssertNil(try fileManager.fileType(url.appendingPathComponent("link3.link")))
        XCTAssertEqual(try fileManager.fileType(url.appendingPathComponent("link2.link")), .typeSymbolicLink)
        XCTAssertEqual(try fileManager.fileType(url.appendingPathComponent("target.txt")), .typeRegular)
    }

    /// Circular links (a -> b -> a) are removable one at a time.
    func testCircularSymbolicLinks() {
        let (fileManager, url) = FileManager.createTempDirectory()
        defer { try? fileManager.removeItem(at: url) }
        fileManager.createFileStructure(nodes: [
            .symbolicLink(name: "link_a.link", target: "link_b.link"),
            .symbolicLink(name: "link_b.link", target: "link_a.link")
        ], at: url)

        let trash = makeTrash(force: true, fileManager: fileManager)
        XCTAssertTrue(trash.removeMultiple(paths: ["./link_a.link"]))

        XCTAssertNil(try fileManager.fileType(url.appendingPathComponent("link_a.link")))
        XCTAssertEqual(try fileManager.fileType(url.appendingPathComponent("link_b.link")), .typeSymbolicLink)
    }

    /// Links to missing relative, parent-relative, and absolute targets are all
    /// removable.
    func testBrokenSymbolicLinks() {
        let (fileManager, url) = FileManager.createTempDirectory()
        defer { try? fileManager.removeItem(at: url) }
        fileManager.createFileStructure(nodes: [
            .symbolicLink(name: "broken1.link", target: "nonexistent.txt"),
            .symbolicLink(name: "broken2.link", target: "../outside/file.txt"),
            .symbolicLink(name: "broken3.link", target: "/absolute/nonexistent.txt")
        ], at: url)

        let trash = makeTrash(force: true, fileManager: fileManager)
        XCTAssertTrue(trash.removeMultiple(paths: ["./broken1.link", "./broken2.link", "./broken3.link"]))

        XCTAssertNil(try fileManager.fileType(url.appendingPathComponent("broken1.link")))
        XCTAssertNil(try fileManager.fileType(url.appendingPathComponent("broken2.link")))
        XCTAssertNil(try fileManager.fileType(url.appendingPathComponent("broken3.link")))
    }

    /// Mixed hard and symbolic links to one file: removing either kind of link
    /// leaves the original and the other links alone.
    func testMixedLinkScenario() {
        let (fileManager, url) = FileManager.createTempDirectory()
        defer { try? fileManager.removeItem(at: url) }
        fileManager.createFileStructure(nodes: [
            .file(name: "original.txt", content: "original content"),
            .hardLink(name: "hard1.txt", target: "original.txt"),
            .hardLink(name: "hard2.txt", target: "original.txt"),
            .symbolicLink(name: "sym_to_original.link", target: "original.txt"),
            .symbolicLink(name: "sym_to_hard.link", target: "hard1.txt"),
            .directory(name: "subdir", sub: [
                .symbolicLink(name: "sym_to_parent.link", target: "../original.txt")
            ])
        ], at: url)

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

    /// Relative and absolute links behave the same, and stay removable after
    /// their target is gone.
    func testAbsoluteRelativeLinks() {
        let (fileManager, url) = FileManager.createTempDirectory()
        defer { try? fileManager.removeItem(at: url) }
        let absoluteTarget = url.appendingPathComponent("target.txt").path
        fileManager.createFileStructure(nodes: [
            .file(name: "target.txt", content: "target content"),
            .symbolicLink(name: "relative.link", target: "target.txt"),
            .symbolicLink(name: "absolute.link", target: absoluteTarget),
            .directory(name: "subdir", sub: [
                .symbolicLink(name: "relative_up.link", target: "../target.txt"),
                .symbolicLink(name: "absolute_from_sub.link", target: absoluteTarget)
            ])
        ], at: url)

        let trash = makeTrash(force: true, recursive: true, fileManager: fileManager)

        XCTAssertEqual(try fileManager.fileType(url.appendingPathComponent("relative.link")), .typeSymbolicLink)
        XCTAssertEqual(try fileManager.fileType(url.appendingPathComponent("absolute.link")), .typeSymbolicLink)

        // Remove the target - links become broken but should still be removable
        XCTAssertTrue(trash.removeMultiple(paths: ["./target.txt"]))
        XCTAssertTrue(trash.removeMultiple(paths: ["./relative.link", "./absolute.link"]))
    }
}
