public final class ByteLRUCache<Key: Hashable, Value> {
    private final class Node {
        let key: Key
        var value: Value
        var cost: Int
        weak var previous: Node?
        var next: Node?

        init(key: Key, value: Value, cost: Int) {
            self.key = key
            self.value = value
            self.cost = cost
        }
    }

    public let byteLimit: Int
    public private(set) var totalCost: Int = 0

    private var entries: [Key: Node] = [:]
    private var leastRecent: Node?
    private var mostRecent: Node?

    public init(byteLimit: Int) {
        precondition(byteLimit >= 0, "ByteLRUCache byte limit cannot be negative")
        self.byteLimit = byteLimit
    }

    public var count: Int {
        entries.count
    }

    public var isEmpty: Bool {
        entries.isEmpty
    }

    public var keysFromLeastToMostRecent: [Key] {
        var keys: [Key] = []
        keys.reserveCapacity(entries.count)

        var current = leastRecent
        while let node = current {
            keys.append(node.key)
            current = node.next
        }
        return keys
    }

    public func contains(_ key: Key) -> Bool {
        entries[key] != nil
    }

    public func cost(forKey key: Key) -> Int? {
        entries[key]?.cost
    }

    public func value(forKey key: Key) -> Value? {
        guard let node = entries[key] else { return nil }
        makeMostRecent(node)
        return node.value
    }

    @discardableResult
    public func insert(_ value: Value, forKey key: Key, cost: Int) -> Bool {
        guard cost >= 0 else { return false }

        if let existing = entries[key] {
            remove(existing)
        }

        guard cost <= byteLimit else { return false }

        while totalCost > byteLimit - cost, let node = leastRecent {
            remove(node)
        }

        let node = Node(key: key, value: value, cost: cost)
        entries[key] = node
        appendAsMostRecent(node)
        totalCost += cost
        return true
    }

    @discardableResult
    public func removeValue(forKey key: Key) -> Value? {
        guard let node = entries[key] else { return nil }
        let value = node.value
        remove(node)
        return value
    }

    public func removeAll(keepingCapacity keepCapacity: Bool = false) {
        entries.removeAll(keepingCapacity: keepCapacity)
        leastRecent = nil
        mostRecent = nil
        totalCost = 0
    }

    private func makeMostRecent(_ node: Node) {
        guard mostRecent !== node else { return }
        unlink(node)
        appendAsMostRecent(node)
    }

    private func appendAsMostRecent(_ node: Node) {
        node.previous = mostRecent
        node.next = nil
        mostRecent?.next = node
        mostRecent = node
        if leastRecent == nil {
            leastRecent = node
        }
    }

    private func remove(_ node: Node) {
        entries.removeValue(forKey: node.key)
        unlink(node)
        totalCost -= node.cost
    }

    private func unlink(_ node: Node) {
        let previous = node.previous
        let next = node.next

        if let previous {
            previous.next = next
        } else {
            leastRecent = next
        }

        if let next {
            next.previous = previous
        } else {
            mostRecent = previous
        }

        node.previous = nil
        node.next = nil
    }
}
