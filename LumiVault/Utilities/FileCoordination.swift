import Foundation

enum FileCoordination {
    /// Perform a coordinated read of the file at the given URL.
    static func coordinatedRead<T>(at url: URL, body: (URL) throws -> T) throws -> T {
        let coordinator = NSFileCoordinator()
        var coordinatorError: NSError?
        var result: Result<T, Error>?

        coordinator.coordinate(readingItemAt: url, options: [], error: &coordinatorError) { coordinatedURL in
            do {
                result = .success(try body(coordinatedURL))
            } catch {
                result = .failure(error)
            }
        }

        if let error = coordinatorError {
            throw error
        }

        switch result {
        case .success(let value): return value
        case .failure(let error): throw error
        case .none: throw CoordinationError.noResult
        }
    }

    /// Perform a coordinated write to the file at the given URL.
    static func coordinatedWrite(at url: URL, body: (URL) throws -> Void) throws {
        let coordinator = NSFileCoordinator()
        var coordinatorError: NSError?
        var bodyError: Error?

        coordinator.coordinate(writingItemAt: url, options: .forReplacing, error: &coordinatorError) { coordinatedURL in
            do {
                try body(coordinatedURL)
            } catch {
                bodyError = error
            }
        }

        if let error = coordinatorError {
            throw error
        }
        if let error = bodyError {
            throw error
        }
    }

    enum CoordinationError: Error {
        case noResult
    }
}
