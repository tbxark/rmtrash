import Foundation
import ArgumentParser

@main
struct Command: ParsableCommand {

    static var configuration: CommandConfiguration = CommandConfiguration(
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

    @Option(name: .customLong("interactive"), help: "Prompt according to WHEN: never, once (-I), or always (-i). If WHEN is not specified, then prompt always.")
    var interactive: String?

    @Flag(name: [.customLong("one-file-system"), .customShort("x")], help: "When removing a hierarchy recursively, skip any directory that is on a file system different from that of the corresponding command line argument ")
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
            Logger.verbose("Arguments: \(args)")
            if !Trash(config: args).removeMultiple(paths: paths) {
                Command.exit(withError: ExitCode.failure)
            }
        } catch {
            Logger.error("rmtrash: \(error.localizedDescription)")
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
            if let mode = Trash.Config.InteractiveMode(rawValue: interactive) {
                interactiveMode = mode
            } else {
                throw Panic("invalid argument for --interactive: \(interactive)\nTry 'rmtrash --help' for more information.")
            }
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
    func isCrossMountPoint(_ url: URL) throws -> Bool

    func fileType(_ url: URL) -> FileAttributeType?
    func subpaths(atPath path: String, enumerator handler: (String) -> Bool)
}

extension FileManager: FileManagerType {

    public func trashItem(at url: URL) throws {
        Logger.verbose("rmtrash: \(url.path)")
        try trashItem(at: url, resultingItemURL: nil)
    }

    public func isRootDir(_ url: URL) -> Bool {
        return url.standardizedFileURL.path == "/"
    }

    public func isEmptyDirectory(_ url: URL) -> Bool {
        guard let enumerator = enumerator(at: url, includingPropertiesForKeys: nil, options: []) else {
            return true
        }
        return enumerator.nextObject() == nil
    }

    public func isCrossMountPoint(_ url: URL) throws -> Bool {
        let cur = URL(fileURLWithPath: currentDirectoryPath)
        let curVol = try cur.resourceValues(forKeys: [.volumeURLKey, .volumeUUIDStringKey, .volumeIdentifierKey])
        let urlVol = try url.resourceValues(forKeys: [.volumeURLKey, .volumeUUIDStringKey, .volumeIdentifierKey])
        
        // Primary comparison: Volume URL
        if let curVolURL = curVol.volume, let urlVolURL = urlVol.volume {
            if curVolURL == urlVolURL {
                return false
            }
        }
        
        // Secondary comparison: Volume UUID (more reliable for network drives and external storage)
        if let curUUID = curVol.volumeUUIDString, let urlUUID = urlVol.volumeUUIDString {
            if !curUUID.isEmpty && !urlUUID.isEmpty {
                return curUUID != urlUUID
            }
        }
        
        // Tertiary comparison: Volume identifier (fallback for special cases)
        if let curID = curVol.volumeIdentifier, let urlID = urlVol.volumeIdentifier {
            return !curID.isEqual(urlID)
        }
        
        // Conservative fallback: assume different volumes if we can't determine
        return true
    }

    public func fileType(_ url: URL) -> FileAttributeType? {
        guard let attr = try? self.attributesOfItem(atPath: url.path) else {
            return nil
        }
        guard let fileType = attr[.type] as? FileAttributeType else {
            return nil
        }
        return  fileType
    }

    public func subpaths(atPath path: String, enumerator handler: (String) -> Bool) {
        if #available(macOS 10.15, *) {
            if  let enumerator = self.enumerator(at: URL(fileURLWithPath: path),
                                                        includingPropertiesForKeys: [],
                                                        options: [.skipsSubdirectoryDescendants, .producesRelativePathURLs]) {
                for case let fileURL as URL in enumerator {
                    let subPath = URL(fileURLWithPath: path).appendingPathComponent(fileURL.relativePath).relativePath
                    if !handler(subPath) {
                        break
                    }
                }
            }
        } else {
            if let subs = try? self.contentsOfDirectory(atPath: path) {
                for sub in subs {
                    let subPath = URL(fileURLWithPath: path).appendingPathComponent(sub).relativePath
                    if !handler(subPath) {
                        break
                    }
                }
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
public struct Panic: Error, CustomDebugStringConvertible, LocalizedError {
    public let message: String
    public var localizedDescription: String { message }
    public var debugDescription: String { message }
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
        print("\(message) (y/n) ", terminator: "")
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
            if !promptOnceCheck(paths: paths) {
                return false
            }
        }
        var success = true
        for path in paths {
            success = removeOne(path: path) && success
        }
        return success
    }

    @discardableResult private func removeOne(path: String) -> Bool {
        do {
            guard case .info(url: let url, isDir: let isDir) = try permissionCheck(path: path) else {
                return true
            }
            switch (config.interactiveMode, isDir) {
            case (.always, true):
                removeDirectory(path)
            case (.always, false):
                if question.ask("remove file \(path)?") {
                    try fileManager.trashItem(at: url)
                }
            case (.never, _), (.once, _):
                try fileManager.trashItem(at: url)
            }
            return true
        } catch {
            if config.verbose || !config.force { // force will ignore the error
                Logger.error("rmtrash: \(error.localizedDescription)")
            }
        }
        return false
    }

    private func removeDirectory(_ path: String) {
        let url = URL(fileURLWithPath: path)
        // when directory is empty, no examine needed
        if fileManager.isEmptyDirectory(url) {
            removeEmptyDirectory(path)
            return
        }
        guard question.ask("descend into directory: '\(path)'?") else {
            return
        }

        // remove all files or directories in the directory
        fileManager.subpaths(atPath: path, enumerator: { subPath in
            self.removeOne(path: subPath)
        })

        // try to remove the directory after all files in it are removed
        removeEmptyDirectory(path)
    }

    private func removeEmptyDirectory(_ path: String) {
        guard question.ask("remove directory '\(path)'?") else {
            return
        }
        var conf = config
        conf.recursive = false          // no recursive anymore
        conf.emptyDirs = true           // but can remove empty directories
        conf.interactiveMode = .never   // and no interactive mode, because did interactive before
        Trash(config: conf, question: question, fileManager: fileManager).removeOne(path: path)
    }
}

// MARK: Permission Check
extension Trash {

    private func promptOnceCheck(paths: [String]) -> Bool {
        var isDirs = [String: Bool]()
        for path in paths {
            guard let res = fileManager.fileType(URL(fileURLWithPath: path)) else {
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

    private func permissionCheck(path: String) throws -> PermissionCheckResult {
        let url = URL(fileURLWithPath: path)

        // Check for protected paths: . and ..
        // Use the original path string to check for . and .. as they may be resolved by URL
        // Also check for paths ending with . or .. (e.g., ../.., ../../, ./., etc.)
        let normalizedPath = path.hasPrefix("/") ? path : "./" + path
        if normalizedPath == "." || normalizedPath == ".." ||
           normalizedPath.hasSuffix("/.") || normalizedPath.hasSuffix("/..") {
            throw canNotRemovePanic(path: path, err: "Refusing to remove '\(path)' directory")
        }

        // file exists check
        guard let fileType = fileManager.fileType(url) else {
            if !config.force {
                throw canNotRemovePanic(path: path, err: "No such file or directory")
            }
            return .skip // skip nonexistent files when force is set
        }

        let isDir = fileType == .typeDirectory

        // cross mount point check
        if config.oneFileSystem {
            let cross = try fileManager.isCrossMountPoint(url)
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
