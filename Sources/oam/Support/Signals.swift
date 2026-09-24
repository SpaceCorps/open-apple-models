import Dispatch
import Foundation
import Synchronization

/// Delivers SIGINT / SIGTERM to a handler instead of terminating the process.
final class SignalTrap: Sendable {
    private let sources: Mutex<[any DispatchSourceSignal]>

    /// Installs `handler` for `signals` until ``cancel()``.
    init(_ signals: [Int32] = [SIGINT, SIGTERM], handler: @escaping @Sendable (Int32) -> Void) {
        var installed: [any DispatchSourceSignal] = []
        for number in signals {
            signal(number, SIG_IGN)
            let source = DispatchSource.makeSignalSource(signal: number, queue: .global())
            source.setEventHandler { handler(number) }
            source.resume()
            installed.append(source)
        }
        sources = Mutex(installed)
    }

    /// Removes the handlers and restores the default signal actions.
    func cancel() {
        let installed = sources.withLock { sources in
            defer { sources.removeAll() }
            return sources
        }
        for source in installed {
            source.cancel()
        }
        signal(SIGINT, SIG_DFL)
        signal(SIGTERM, SIG_DFL)
    }
}

/// A mutex-protected value that closures can share (unlike `Mutex`, which
/// is non-copyable and cannot be captured).
final class Locked<Value: Sendable>: Sendable {
    private let storage: Mutex<Value>

    init(_ value: Value) { storage = Mutex(value) }

    var value: Value {
        get { storage.withLock { $0 } }
        set { storage.withLock { $0 = newValue } }
    }

    @discardableResult
    func withLock<Result: Sendable>(_ body: (inout Value) -> Result) -> Result {
        storage.withLock { body(&$0) }
    }
}
