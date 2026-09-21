import XCTest
@testable import rmtrash

/// Mapping from command-line flags and environment to `Trash.Config`.
final class CommandParsingTests: XCTestCase {

    /// Parses with an explicit (empty by default) environment so results don't
    /// depend on RMTRASH_INTERACTIVE_MODE in the developer's shell.
    private func config(_ args: [String], env: [String: String] = [:]) throws -> Trash.Config {
        try Command.parse(args).parseArgs(environment: env)
    }

    func testEnvironmentProvidesDefaultInteractiveMode() throws {
        XCTAssertEqual(try config(["x"], env: ["RMTRASH_INTERACTIVE_MODE": "always"]).interactiveMode, .always)
        XCTAssertEqual(try config(["x"], env: ["RMTRASH_INTERACTIVE_MODE": "once"]).interactiveMode, .once)
        // Explicit flags win over the environment.
        XCTAssertEqual(try config(["-I", "x"], env: ["RMTRASH_INTERACTIVE_MODE": "always"]).interactiveMode, .once)
        XCTAssertEqual(try config(["-f", "x"], env: ["RMTRASH_INTERACTIVE_MODE": "always"]).interactiveMode, .never)
    }

    func testInvalidEnvironmentValueFallsBackToNever() throws {
        XCTAssertEqual(try config(["x"], env: ["RMTRASH_INTERACTIVE_MODE": "bogus"]).interactiveMode, .never)
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

    /// `--interactive` requires WHEN (documented in README, man page, and help).
    /// A bare `--interactive` followed by an operand is a parse error rather
    /// than silently consuming the operand as a mode.
    func testInteractiveRequiresValue() {
        XCTAssertThrowsError(try Command.parse(["--interactive"]))
        XCTAssertThrowsError(try Command.parse(["--interactive", "file.txt"]))
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
