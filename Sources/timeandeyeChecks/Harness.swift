import Foundation

/// Micro test harness: the build environment has Command Line Tools only,
/// so neither XCTest nor Swift Testing is available. This provides the
/// minimal assertion vocabulary the check suites need.

struct CheckFailure: Error, CustomStringConvertible {
    let description: String
}

final class Checks {
    private(set) var passed = 0
    private(set) var failed = 0
    private let suite: String

    init(_ suite: String) {
        self.suite = suite
    }

    func check(_ name: String, _ body: () throws -> Void) {
        do {
            try body()
            passed += 1
        } catch {
            failed += 1
            print("FAIL [\(suite)] \(name): \(error)")
        }
    }

    func check(_ name: String, _ body: () async throws -> Void) async {
        do {
            try await body()
            passed += 1
        } catch {
            failed += 1
            print("FAIL [\(suite)] \(name): \(error)")
        }
    }

    func finish() -> (Int, Int) {
        print("\(suite): \(passed) passed, \(failed) failed")
        return (passed, failed)
    }
}

func expect(_ condition: Bool, _ message: @autoclosure () -> String = "expected true") throws {
    if !condition { throw CheckFailure(description: message()) }
}

func expectEq<T: Equatable>(_ actual: T, _ expected: T,
                            _ message: @autoclosure () -> String = "") throws {
    if actual != expected {
        throw CheckFailure(description: "\(message()) expected \(expected), got \(actual)")
    }
}

func expectNil<T>(_ value: T?, _ message: @autoclosure () -> String = "expected nil") throws {
    if let value { throw CheckFailure(description: "\(message()): got \(value)") }
}

func expectClose(_ actual: Double, _ expected: Double, accuracy: Double = 0.001,
                 _ message: @autoclosure () -> String = "") throws {
    if abs(actual - expected) > accuracy {
        throw CheckFailure(description: "\(message()) expected \(expected)±\(accuracy), got \(actual)")
    }
}

func expectThrows(_ message: @autoclosure () -> String = "expected an error",
                  _ body: () throws -> Void) throws {
    do {
        try body()
        throw CheckFailure(description: message())
    } catch is CheckFailure {
        throw CheckFailure(description: message())
    } catch {
        // expected path: any non-CheckFailure error means the body threw
    }
}

func unwrap<T>(_ value: T?, _ message: @autoclosure () -> String = "unexpected nil") throws -> T {
    guard let value else { throw CheckFailure(description: message()) }
    return value
}
