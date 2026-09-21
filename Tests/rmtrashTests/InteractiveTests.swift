import XCTest
@testable import rmtrash

/// `-i` (prompt for every item, walk directories) and `-I` (prompt once).
final class InteractiveTests: CWDRestoringTestCase {

    // MARK: - Basic modes

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

    // MARK: - Interactive directory walk (-i -r)

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

    /// Declining "descend into directory" on a nested directory is a normal
    /// cancellation: that subtree is left untouched, siblings are still
    /// processed, and the parent (now non-empty) is reported as a failure only
    /// because it cannot be removed, never because the user said no.
    func testInteractiveDecliningDescendLeavesSubtreeUntouched() throws {
        let (fileManager, url) = FileManager.createTempDirectory()
        defer { try? fileManager.removeItem(at: url) }
        fileManager.createFileStructure(nodes: [
            .directory(name: "dir", sub: [
                .file(name: "a.txt", content: "a"),
                .directory(name: "keep", sub: [.file(name: "inner.txt", content: "i")])
            ])
        ], at: url)

        /// Says yes to everything except descending into "keep".
        final class SelectiveQuestion: Question {
            private(set) var asked: [String] = []
            func ask(_ message: String) -> Bool {
                asked.append(message)
                return !message.contains("descend into directory: '") || !message.contains("/keep'")
            }
        }
        let q = SelectiveQuestion()
        let mock = RecordingFileManager()
        let trash = makeTrash(interactiveMode: .always, force: false, recursive: true, fileManager: mock, question: q)

        let dirPath = url.appendingPathComponent("dir").path
        XCTAssertFalse(trash.removeMultiple(paths: [dirPath]), "parent cannot be removed while 'keep' remains")
        XCTAssertEqual(mock.removed, ["a.txt"])
        XCTAssertEqual(try mock.fileType(url.appendingPathComponent("dir/keep/inner.txt")), .typeRegular)
        XCTAssertFalse(q.asked.contains { $0.contains("inner.txt") }, "never prompted for contents of the declined subtree")
    }

    // MARK: - Prompt-once threshold (-I)

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

    /// Without -r, directories count like any other operand: three or fewer
    /// operands never prompt (GNU rm -I).
    func testInteractiveOnceDoesNotPromptForFewDirectoriesWithoutRecursive() {
        let (fileManager, url) = FileManager.createTempDirectory()
        defer { try? fileManager.removeItem(at: url) }
        fileManager.createFileStructure(nodes: [
            .directory(name: "d1", sub: []),
            .directory(name: "d2", sub: [])
        ], at: url)

        let q = RecordingQuestion(answer: false)
        let trash = makeTrash(interactiveMode: .once, force: false, emptyDirs: true, fileManager: fileManager, question: q)

        XCTAssertTrue(trash.removeMultiple(paths: [url.appendingPathComponent("d1").path, url.appendingPathComponent("d2").path]))
        XCTAssertTrue(q.asked.isEmpty)
        XCTAssertNil(try fileManager.fileType(url.appendingPathComponent("d1")))
    }

    /// With -r, even a single operand prompts, and the wording says so.
    func testInteractiveOncePromptsForAnyOperandWhenRecursive() {
        let (mock, paths, cleanup) = makeFilesScenario(["a.txt"])
        defer { cleanup() }

        let q = RecordingQuestion(answer: false)
        let trash = makeTrash(interactiveMode: .once, force: false, recursive: true, fileManager: mock, question: q)

        XCTAssertTrue(trash.removeMultiple(paths: paths))
        XCTAssertEqual(q.asked, ["recursively remove 1 file?"])
        XCTAssertTrue(mock.removed.isEmpty)
    }

    /// More than three operands without -r prompts with plain "remove" wording
    /// and counts directories and files separately.
    func testInteractiveOnceWordingWithoutRecursive() {
        let (fileManager, url) = FileManager.createTempDirectory()
        defer { try? fileManager.removeItem(at: url) }
        fileManager.createFileStructure(nodes: [
            .directory(name: "d1", sub: []),
            .file(name: "a.txt"), .file(name: "b.txt"), .file(name: "c.txt")
        ], at: url)

        let q = RecordingQuestion(answer: false)
        let trash = makeTrash(interactiveMode: .once, force: false, emptyDirs: true, fileManager: fileManager, question: q)
        let paths = ["d1", "a.txt", "b.txt", "c.txt"].map { url.appendingPathComponent($0).path }

        XCTAssertTrue(trash.removeMultiple(paths: paths))
        XCTAssertEqual(q.asked, ["remove 1 dir and 3 files?"])
    }
}
