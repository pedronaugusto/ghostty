import Combine

extension Array {
    subscript(safe index: Int) -> Element? {
        return indices.contains(index) ? self[index] : nil
    }

    /// Returns the index before i, with wraparound. Assumes i is a valid index.
    func indexWrapping(before i: Int) -> Int {
        if i == 0 {
            return count - 1
        }

        return i - 1
    }

    /// Returns the index after i, with wraparound. Assumes i is a valid index.
    func indexWrapping(after i: Int) -> Int {
        if i == count - 1 {
            return 0
        }

        return i + 1
    }
}

extension Array where Element == String {
    /// Executes a closure with an array of C string pointers.
    func withCStrings<T>(_ body: ([UnsafePointer<Int8>?]) throws -> T) rethrows -> T {
        // Handle empty array
        if isEmpty {
            return try body([])
        }

        // Recursive helper to process strings
        func helper(index: Int, accumulated: [UnsafePointer<Int8>?], body: ([UnsafePointer<Int8>?]) throws -> T) rethrows -> T {
            if index == count {
                return try body(accumulated)
            }

            return try self[index].withCString { cStr in
                var newAccumulated = accumulated
                newAccumulated.append(cStr)
                return try helper(index: index + 1, accumulated: newAccumulated, body: body)
            }
        }

        return try helper(index: 0, accumulated: [], body: body)
    }
}

// MARK: Combine

extension Array where Element: Identifiable {
    /// Builds a publisher that emits current values for all views keyed by view ID.
    ///
    /// The returned publisher emits a full `[Element.ID: Value]` snapshot whenever
    /// any view publishes through the provided publisher key path.
    func valuesPublisher<Value>(
        valueKeyPath: KeyPath<Element, Value>,
        publisherKeyPath: KeyPath<Element, Published<Value>.Publisher>
    ) -> AnyPublisher<[Element.ID: Value], Never> {
        let views = self
        guard !views.isEmpty else {
            // With nothing to watch, immediately publish an empty snapshot.
            // `Just([:])` keeps the return type simple and makes downstream usage easy.
            return Just([:]).eraseToAnyPublisher()
        }

        // Capture each view's current value up front.
        // We key by `Element.ID` so updates can replace the correct entry later.
        // This avoids waiting for all views to emit before consumers see data.
        let initial = Dictionary(uniqueKeysWithValues: views.map { view in
            (view.id, view[keyPath: valueKeyPath])
        })

        // Build one publisher per view from the requested key path.
        // Each emission is mapped into `(id, value)` so we know which entry changed.
        // `MergeMany` combines all per-view streams into a single update stream.
        let updates = Publishers.MergeMany(views.map { view in
            view[keyPath: publisherKeyPath]
                .map { (view.id, $0) }
                .eraseToAnyPublisher()
        })

        return updates
            // Accumulate updates into a full "latest value per ID" dictionary.
            // This turns incremental events into complete state snapshots.
            .scan(initial) { state, update in
                var state = state
                state[update.0] = update.1
                return state
            }
            // Emit the initial snapshot first so subscribers always get a
            // complete value dictionary immediately upon subscription.
            .prepend(initial)
            // Hide implementation details and expose a stable API type.
            .eraseToAnyPublisher()
    }
}
