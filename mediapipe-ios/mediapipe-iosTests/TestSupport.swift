import Foundation
import XCTest

func fixtureURL(_ name: String, extension fileExtension: String) throws -> URL {
  try XCTUnwrap(Bundle.main.url(forResource: name, withExtension: fileExtension),
    "Missing app fixture: \(name).\(fileExtension)")
}

/// Poll observable state without blocking MainActor. Every wait has a deadline
/// and honors task cancellation; timeout throws instead of continuing with bad state.
@MainActor
func waitUntil(
  _ message: String,
  timeout: TimeInterval = 5,
  condition: () -> Bool
) async throws {
  let deadline = ContinuousClock.now + .seconds(timeout)
  while !condition() {
    try Task.checkCancellation()
    guard ContinuousClock.now < deadline else {
      throw NSError(domain: "MediaPipeIOSTests.Timeout", code: 1,
        userInfo: [NSLocalizedDescriptionKey: message])
    }
    try await Task.sleep(for: .milliseconds(25))
  }
}

extension XCTestCase {
  /// Bridge completion handlers with an XCTest deadline, not an unbounded continuation.
  func callbackValue<Value: Sendable>(
    _ description: String,
    timeout: TimeInterval = 15,
    start: (@escaping @Sendable (Result<Value, Error>) -> Void) -> Void
  ) async throws -> Value {
    let result = TestCallbackResult<Value>()
    let completed = expectation(description: description)
    completed.assertForOverFulfill = true
    start { value in
      result.store(value)
      completed.fulfill()
    }
    await fulfillment(of: [completed], timeout: timeout)
    return try XCTUnwrap(result.value, "No callback result: \(description)").get()
  }
}

private final class TestCallbackResult<Value: Sendable>: @unchecked Sendable {
  private let lock = NSLock()
  private var stored: Result<Value, Error>?

  func store(_ value: Result<Value, Error>) {
    lock.lock()
    defer { lock.unlock() }
    stored = value
  }

  var value: Result<Value, Error>? {
    lock.lock()
    defer { lock.unlock() }
    return stored
  }
}
