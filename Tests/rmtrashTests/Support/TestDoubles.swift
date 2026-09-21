import XCTest
@testable import rmtrash

// MARK: - Question doubles

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

// MARK: - FileManager doubles

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

// MARK: - Test case base

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

// MARK: - Factory

func makeTrash(
    interactiveMode: Trash.Config.InteractiveMode = .never,
    force: Bool = true,
    recursive: Bool = false,
    emptyDirs: Bool = false,
    preserveRoot: Bool = true,
    oneFileSystem: Bool = false,
    verbose: Bool = false,
    fileManager: FileManagerType = TestFileManager(),
    question: Question = StaticAnswer(value: true)
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
