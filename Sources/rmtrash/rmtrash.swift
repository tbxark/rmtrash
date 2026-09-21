import Foundation
import ArgumentParser

@main
struct Command: ParsableCommand {

    static let configuration: CommandConfiguration = CommandConfiguration(
        commandName: "rmtrash",
        abstract: "Move files and directories to the trash.",
        discussion: "rmtrash is a small utility that will move the file to macOS's Trash rather than obliterating the file (as rm does).",
        version: "0.8.0",
        shouldDisplay: true,
        subcommands: [],
        helpNames: .long,
        aliases: ["trash", "del", "rm"]
    )

    @Flag(name: .shortAndLong, help: "Ignore nonexistant files, and never prompt before removing.")
    var force: Bool = false

    @Flag(name: .customShort("i"), help: "Prompt before every removal.")
    var interactiveAlways: Bool = false

    @Flag(name: .customShort("I"), help: "Prompt once before removing more than three files, or when removing recursively. This option is less intrusive than -i, but still gives protection against most mistakes.")
    var interactiveOnce: Bool = false

    @Option(name: .customLong("interactive"), help: "Prompt according to WHEN: never, once (-I), or always (-i). WHEN is required; use -i if you want the equivalent of '--interactive=always'.")
    var interactive: Trash.Config.InteractiveMode?

    @Flag(name: [.customLong("one-file-system"), .customShort("x")], help: "When removing a hierarchy recursively, refuse to remove a command line argument if any directory beneath it is on a different file system. Unlike rm, nothing is removed in that case: a directory is moved to the Trash as a whole, so the foreign file system cannot be skipped.")
    var oneFileSystem: Bool = false

    @Flag(name: .customLong("preserve-root"), inversion: .prefixedNo, help: "Do not remove \"/\" (the root directory), which is the default behavior.")
    var preserveRoot: Bool = true

    @Flag(name: [.short, .long, .customShort("R")], help: "Recursively remove directories and their contents.")
    var recursive: Bool = false

    @Flag(name: [.customShort("d"), .customLong("dir")], help: "Remove empty directories. This option permits you to remove a directory without specifying -r/-R/--recursive, provided that the directory is empty. In other words, rm -d is equivalent to using rmdir.")
    var emptyDirs: Bool = false

    @Flag(name: .shortAndLong, help: "Verbose mode; explain at all times what is being done.")
    var verbose: Bool = false

    @Argument(help: "The files or directories to move to trash.")
    var paths: [String] = []

    func run() throws {
        do {
            let args = try parseArgs()
            Logger.level = args.verbose ? .verbose : .error
            if !Trash(config: args).removeMultiple(paths: paths) {
                Command.exit(withError: ExitCode.failure)
            }
        } catch {
            Logger.error("rmtrash: \(error.localizedDescription)")
            Command.exit(withError: ExitCode.failure)
        }
    }

    func parseArgs() throws -> Trash.Config {
        if paths.isEmpty {
            if force {
                // -f with no operands should succeed quietly
                return Trash.Config(
                    interactiveMode: .never,
                    force: true,
                    recursive: recursive,
                    emptyDirs: emptyDirs,
                    preserveRoot: preserveRoot,
                    oneFileSystem: oneFileSystem,
                    verbose: verbose
                )
            }
            throw Panic("missing operand\nTry 'rmtrash --help' for more information.")
        }
        var interactiveMode = Trash.Config.InteractiveMode(rawValue: ProcessInfo.processInfo.environment["RMTRASH_INTERACTIVE_MODE"] ?? "never") ?? .never
        if force {
            interactiveMode = .never
        } else if interactiveAlways {
            interactiveMode = .always
        } else if interactiveOnce {
            interactiveMode = .once
        } else if let interactive = interactive {
            interactiveMode = interactive
        }
        return Trash.Config(
            interactiveMode: interactiveMode,
            force: force,
            recursive: recursive,
            emptyDirs: emptyDirs,
            preserveRoot: preserveRoot,
            oneFileSystem: oneFileSystem,
            verbose: verbose
        )
    }
}

// MARK: - FileManager

public protocol FileManagerType {
    func trashItem(at url: URL) throws

    func isRootDir(_ url: URL) -> Bool
    func isEmptyDirectory(_ url: URL) -> Bool
    // base is the command-line argument (or its parent during recursion). rm semantics
    // dictate the comparison is against the command-line argument, not the CWD.
    func isCrossMountPoint(_ url: URL, against base: URL) throws -> Bool

    // Returns nil only when the path does not exist (ENOENT). Any other failure
    // (permission denied, not a directory, ...) is thrown so it can be reported
    // instead of being mistaken for "no such file".
    func fileType(_ url: URL) throws -> FileAttributeType?
    func subpaths(atPath path: String, enumerator handler: (String) -> Bool)
}

extension FileManager: FileManagerType {

    public func trashItem(at url: URL) throws {
        try trashItem(at: url, resultingItemURL: nil)
        // Report only after the move succeeded, in the form the user typed the
        // path (relativePath keeps relative operands relative, like rm -v).
        Logger.verbose("moved '\(url.relativePath)' to trash")
    }

    public func isRootDir(_ url: URL) -> Bool {
        return url.standardizedFileURL.path == "/"
    }

    public func isEmptyDirectory(_ url: URL) -> Bool {
        // If the directory cannot be read (e.g. permission denied), conservatively
        // treat it as non-empty so the caller refuses to remove it instead of
        // silently proceeding. Note: `enumerator(at:)` never returns nil and
        // swallows read errors, which is why `contentsOfDirectory` is used here.
        guard let contents = try? contentsOfDirectory(atPath: url.path) else {
            return false
        }
        return contents.isEmpty
    }

    public func isCrossMountPoint(_ url: URL, against base: URL) throws -> Bool {
        let baseVol = try base.resourceValues(forKeys: [.volumeURLKey, .volumeUUIDStringKey, .volumeIdentifierKey])
        let urlVol = try url.resourceValues(forKeys: [.volumeURLKey, .volumeUUIDStringKey, .volumeIdentifierKey])

        // Primary comparison: Volume URL
        if let baseVolURL = baseVol.volume, let urlVolURL = urlVol.volume {
            if baseVolURL == urlVolURL {
                return false
            }
        }

        // Secondary comparison: Volume UUID (more reliable for network drives and external storage)
        if let baseUUID = baseVol.volumeUUIDString, let urlUUID = urlVol.volumeUUIDString {
            if !baseUUID.isEmpty && !urlUUID.isEmpty {
                return baseUUID != urlUUID
            }
        }

        // Tertiary comparison: Volume identifier (fallback for special cases)
        if let baseID = baseVol.volumeIdentifier, let urlID = urlVol.volumeIdentifier {
            return !baseID.isEqual(urlID)
        }

        // Conservative fallback: assume different volumes if we can't determine
        return true
    }

    public func fileType(_ url: URL) throws -> FileAttributeType? {
        do {
            let attr = try self.attributesOfItem(atPath: url.path)
            return attr[.type] as? FileAttributeType
        } catch let error where error.posixCode == ENOENT {
            return nil
        }
    }

    public func subpaths(atPath path: String, enumerator handler: (String) -> Bool) {
        guard let enumerator = self.enumerator(at: URL(fileURLWithPath: path),
                                               includingPropertiesForKeys: [],
                                               options: [.skipsSubdirectoryDescendants, .producesRelativePathURLs]) else {
            return
        }
        for case let fileURL as URL in enumerator {
            let subPath = URL(fileURLWithPath: path).appendingPathComponent(fileURL.relativePath).relativePath
            if !handler(subPath) {
                break
            }
        }
    }

}

// MARK: - Logger
public struct Logger {
    public enum Level: Int {
        case verbose = 0
        case error = 1
    }

    public static var level: Level = .error

    public struct StdError: TextOutputStream {
        public mutating func write(_ string: String) {
            fputs(string, stderr)
        }
    }

    public static func verbose(_ message: String) {
        guard level.rawValue <= Level.verbose.rawValue else { return }
        print(message)
    }

    public static func error(_ message: String) {
        guard level.rawValue <= Level.error.rawValue else { return }
        var stdError = StdError()
        print(message, to: &stdError)
    }
}

// MARK: - Error
extension Error {
    /// The POSIX errno behind this error, if one can be determined. Foundation
    /// wraps filesystem failures in CocoaError with the POSIX error underneath.
    var posixCode: Int32? {
        let ns = self as NSError
        if ns.domain == NSPOSIXErrorDomain {
            return Int32(ns.code)
        }
        if let underlying = ns.userInfo[NSUnderlyingErrorKey] as? NSError {
            return underlying.posixCode
        }
        if ns.domain == NSCocoaErrorDomain {
            switch ns.code {
            case NSFileNoSuchFileError, NSFileReadNoSuchFileError:
                return ENOENT
            case NSFileReadNoPermissionError, NSFileWriteNoPermissionError:
                return EACCES
            default:
                return nil
            }
        }
        return nil
    }

    /// rm-style short description ("Permission denied") when a POSIX errno is
    /// known; otherwise Foundation's localized description.
    var rmDescription: String {
        if let code = posixCode {
            return String(cString: strerror(code))
        }
        return localizedDescription
    }
}

public struct Panic: Error, LocalizedError {
    public let message: String
    // LocalizedError derives localizedDescription from errorDescription.
    public var errorDescription: String? { message }
    public init(_ message: String) {
        self.message = message
    }
}

// MARK: - Question
public protocol Question {
    func ask(_ message: String) -> Bool
}

public struct CommandLineQuestion: Question {
    public init() {}

    public func ask(_ message: String) -> Bool {
        // Prompts go to stderr, like rm, so they are visible even when stdout is
        // redirected and never pollute stdout for scripts. Flush explicitly: the
        // prompt has no trailing newline, so buffering could otherwise hold it
        // back until after the user is expected to answer.
        var stdError = Logger.StdError()
        print("\(message) (y/n) ", terminator: "", to: &stdError)
        fflush(stderr)
        guard let answer = readLine() else {
            return false
        }
        return answer.lowercased() == "y" || answer.lowercased() == "yes"
    }
}

// MARK: - Trash
public struct Trash {

    public struct Config: Codable {
        public enum InteractiveMode: String, ExpressibleByArgument, Codable {
            case always
            case once
            case never
        }

        public var interactiveMode: InteractiveMode
        public var force: Bool
        public var recursive: Bool
        public var emptyDirs: Bool
        public var preserveRoot: Bool
        public var oneFileSystem: Bool
        public var verbose: Bool

        public init(interactiveMode: InteractiveMode, force: Bool, recursive: Bool, emptyDirs: Bool, preserveRoot: Bool, oneFileSystem: Bool, verbose: Bool) {
            self.interactiveMode = interactiveMode
            self.force = force
            self.recursive = recursive
            self.emptyDirs = emptyDirs
            self.preserveRoot = preserveRoot
            self.oneFileSystem = oneFileSystem
            self.verbose = verbose
        }
    }

    public let config: Config
    public let question: Question
    public let fileManager: FileManagerType

    public init(config: Config, question: Question = CommandLineQuestion(), fileManager: FileManagerType = FileManager.default) {
        self.config = config
        self.question = question
        self.fileManager = fileManager
    }

    private func canNotRemovePanic(path: String, err: String) -> Panic {
        return Panic("cannot remove '\(path)': \(err)")
    }

}

// MARK: Remove handling
extension Trash {

    public func removeMultiple(paths: [String]) -> Bool {
        guard paths.count > 0 else {
            return true
        }
        if config.interactiveMode == .once {
            // User declining the once-prompt is a normal cancellation, not a failure.
            if !promptOnceCheck(paths: paths) {
                return true
            }
        }
        var success = true
        for path in paths {
            // Command-line arguments have no enclosing base; pass nil so they aren't
            // subject to cross-mount checks against themselves.
            success = removeOne(path: path, base: nil) && success
        }
        return success
    }

    @discardableResult private func removeOne(path: String, base: URL?) -> Bool {
        do {
            guard case .info(url: let url, isDir: let isDir) = try permissionCheck(path: path, base: base) else {
                return true
            }
            switch (config.interactiveMode, isDir) {
            case (.always, true):
                return removeDirectory(path, rootURL: url)
            case (.always, false):
                if question.ask("remove file \(path)?") {
                    try fileManager.trashItem(at: url)
                }
            case (.never, _), (.once, _):
                try fileManager.trashItem(at: url)
            }
            return true
        } catch {
            // Errors that survive permissionCheck (e.g. permission denied, cross-device)
            // are always reported, matching rm's behavior where -f only silences
            // "does not exist" errors (already handled via .skip in permissionCheck).
            Logger.error("rmtrash: \(error.localizedDescription)")
        }
        return false
    }

    // Returns false if the directory or any item beneath it could not be removed.
    // A user declining a prompt is a normal cancellation, not a failure.
    private func removeDirectory(_ path: String, rootURL: URL) -> Bool {
        let url = URL(fileURLWithPath: path)
        // when directory is empty, no examine needed
        if fileManager.isEmptyDirectory(url) {
            return removeEmptyDirectory(path)
        }
        guard question.ask("descend into directory: '\(path)'?") else {
            return true
        }

        // Remove every file or directory in the directory. A failure on one child
        // must not abort the walk: keep enumerating siblings and report the
        // aggregate result, matching rm which continues past errors.
        var success = true
        fileManager.subpaths(atPath: path, enumerator: { subPath in
            // Children are compared against the cmd-line root for --one-file-system.
            success = self.removeOne(path: subPath, base: rootURL) && success
            return true
        })

        // try to remove the directory after all files in it are removed
        return removeEmptyDirectory(path) && success
    }

    private func removeEmptyDirectory(_ path: String) -> Bool {
        guard question.ask("remove directory '\(path)'?") else {
            return true
        }
        var conf = config
        conf.recursive = false          // no recursive anymore
        conf.emptyDirs = true           // but can remove empty directories
        conf.interactiveMode = .never   // and no interactive mode, because did interactive before
        return Trash(config: conf, question: question, fileManager: fileManager).removeOne(path: path, base: nil)
    }
}

// MARK: Permission Check
extension Trash {

    private func promptOnceCheck(paths: [String]) -> Bool {
        var isDirs = [String: Bool]()
        for path in paths {
            // Unreadable or missing operands are reported later by removeOne;
            // they don't count toward the prompt.
            guard let res = try? fileManager.fileType(URL(fileURLWithPath: path)) else {
                continue
            }
            isDirs[path] = res == .typeDirectory
        }
        let dirs = isDirs.filter({ $0.value }).keys.map({ $0 })
        let fileCount = isDirs.filter({ $0.value == false }).count
        let dirWord = dirs.count == 1 ? "dir" : "dirs"
        let fileWord = fileCount == 1 ? "file" : "files"
        switch (dirs.count > 0, fileCount > 0) {
        case (true, false):
            return question.ask("recursively remove \(dirs.count) \(dirWord)?")
        case (false, true):
            return fileCount <= 3 || question.ask("remove \(fileCount) \(fileWord)?")
        case (true, true):
            return question.ask("recursively remove \(dirs.count) \(dirWord) and \(fileCount) \(fileWord)?")
        case (false, false):
            return true
        }
    }

    // Recursively scans `root`'s subtree, returning the path of the first
    // descendant that is on a different volume than `root`, or nil if the whole
    // tree is on one volume. Symbolic links are not followed (they report as
    // .typeSymbolicLink, so we never descend through them), which also avoids
    // cycles. A resource-value lookup that fails is treated as "same volume" so
    // an unreadable attribute can't block an otherwise valid removal.
    private func firstCrossMountDescendant(root: URL) -> String? {
        var crossed: String?
        func walk(_ dir: URL) {
            fileManager.subpaths(atPath: dir.path) { subPath in
                let subURL = URL(fileURLWithPath: subPath)
                if (try? fileManager.isCrossMountPoint(subURL, against: root)) == true {
                    crossed = subPath
                    return false
                }
                if (try? fileManager.fileType(subURL)) == .typeDirectory {
                    walk(subURL)
                }
                return crossed == nil
            }
        }
        walk(root)
        return crossed
    }

    private func permissionCheck(path: String, base: URL?) throws -> PermissionCheckResult {
        // Protected paths check: refuse to remove '.' and '..' by basename,
        // matching GNU/BSD rm. lastPathComponent already normalizes trailing
        // slashes, so this also covers "foo/./", "foo/../", "/.", "/..", etc.
        let basename = (path as NSString).lastPathComponent
        if basename == "." || basename == ".." {
            throw canNotRemovePanic(path: path, err: "Refusing to remove '.' or '..' directory")
        }

        let url = URL(fileURLWithPath: path)

        // file exists check. Only "does not exist" is silenced by -f; any other
        // stat failure (permission denied, not a directory, ...) is reported
        // regardless of -f, matching rm.
        let maybeFileType: FileAttributeType?
        do {
            maybeFileType = try fileManager.fileType(url)
        } catch {
            throw canNotRemovePanic(path: path, err: error.rmDescription)
        }
        guard let fileType = maybeFileType else {
            if !config.force {
                throw canNotRemovePanic(path: path, err: "No such file or directory")
            }
            return .skip // skip nonexistent files when force is set
        }

        let isDir = fileType == .typeDirectory

        // cross mount point check for items reached while walking a directory
        // interactively (base is the enclosing directory). The command-line
        // argument itself (base == nil) is the reference point, so it can never
        // be "cross-mount" relative to itself. In practice a command-line tree
        // containing a foreign volume is already refused as a whole below, so
        // this is defence in depth for mounts that appear mid-walk.
        if config.oneFileSystem, let base = base {
            let cross = try fileManager.isCrossMountPoint(url, against: base)
            if cross {
                throw canNotRemovePanic(path: path, err: "Cross-device link")
            }
        }

        // directory check
        if isDir {
            // root directory check
            if fileManager.isRootDir(url) && config.preserveRoot {
                throw canNotRemovePanic(path: path, err: "Preserve root")
            }

            // one-file-system check: a command-line directory argument (base == nil)
            // is refused as a whole if any descendant lives on a different volume,
            // so a mount point nested inside it is never swept into the Trash.
            // Unlike rm -x, rmtrash cannot "skip" the foreign volume and remove the
            // rest: a directory is moved to the Trash as a single item, so the
            // only safe answer is to refuse the whole argument and point at the
            // offending path.
            if config.oneFileSystem, base == nil, let foreign = firstCrossMountDescendant(root: url) {
                throw canNotRemovePanic(path: path, err: "Cross-device link ('\(foreign)' is on a different file system)")
            }

            // recursive check
            if !config.recursive {
                if config.emptyDirs {
                    if !fileManager.isEmptyDirectory(url) {
                        // can remove empty directory when emptyDirs set but not recursive
                        throw canNotRemovePanic(path: path, err: "Directory not empty")
                    }
                } else {
                    // can not remove directory when not recursive and not emptyDirs
                    throw canNotRemovePanic(path: path, err: "Is a directory")
                }
            }
        }

        return .info(url: url, isDir: isDir)
    }

    enum PermissionCheckResult {
        case skip
        case info(url: URL, isDir: Bool)
    }
}
