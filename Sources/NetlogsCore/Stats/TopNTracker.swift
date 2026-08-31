import Foundation

/// Keeps only the `capacity` smallest- or largest-scoring elements seen, via a
/// bounded sorted insert — never sorts full history (plan §8.1).
///
/// Internally the buffer is kept sorted ascending by score. For `capacity = 10`
/// the insert is a shift in a ≤10-element array: O(1) amortised.
public struct TopNTracker<Element>: Sendable where Element: Sendable {

    public enum Keep: Sendable {
        case smallest
        case largest
    }

    public let capacity: Int
    public let keep: Keep
    private let score: @Sendable (Element) -> Double
    /// Always sorted ascending by score.
    private var buffer: [Element] = []

    public init(capacity: Int, keep: Keep, score: @escaping @Sendable (Element) -> Double) {
        precondition(capacity > 0)
        self.capacity = capacity
        self.keep = keep
        self.score = score
    }

    public mutating func offer(_ element: Element) {
        let s = score(element)

        if buffer.count == capacity {
            switch keep {
            case .smallest:
                if s >= score(buffer[buffer.count - 1]) { return } // not small enough
            case .largest:
                if s <= score(buffer[0]) { return }                // not large enough
            }
        }

        var insertAt = buffer.count
        for i in 0..<buffer.count where s < score(buffer[i]) {
            insertAt = i
            break
        }
        buffer.insert(element, at: insertAt)

        if buffer.count > capacity {
            switch keep {
            case .smallest: buffer.removeLast()
            case .largest:  buffer.removeFirst()
            }
        }
    }

    /// `.smallest` → ascending by score. `.largest` → descending by score.
    public var elements: [Element] {
        keep == .smallest ? buffer : buffer.reversed()
    }

    public var count: Int { buffer.count }
}
