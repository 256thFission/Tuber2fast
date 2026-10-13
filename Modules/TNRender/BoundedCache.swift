/// One shape for every bounded in-memory cache in this project: values by
/// key, oldest evicted first once the byte total passes the bound. A value
/// larger than the bound is not kept and evicts nothing for it. Each
/// instance still declares its owner, bound, and evictor where it is
/// declared, as the contract requires; this type is the mechanism, not the
/// declaration.
package struct BoundedCache<Key: Hashable, Value> {
    package let bound: Int
    package let cost: (Value) -> Int
    private var values: [Key: Value] = [:]
    private var order: [Key] = []
    package private(set) var bytes = 0

    package init(bound: Int, cost: @escaping (Value) -> Int) {
        self.bound = bound
        self.cost = cost
    }

    package subscript(key: Key) -> Value? { values[key] }

    /// A key already present is replaced and becomes the newest. An oversize
    /// value still removes the old one, so a key never answers with a value
    /// it was told to replace.
    package mutating func insert(_ value: Value, for key: Key) {
        if let replaced = values.removeValue(forKey: key) {
            bytes -= cost(replaced)
            order.removeAll { $0 == key }
        }
        guard cost(value) <= bound else { return }
        values[key] = value
        order.append(key)
        bytes += cost(value)
        while bytes > bound, let oldest = order.first {
            order.removeFirst()
            if let removed = values.removeValue(forKey: oldest) { bytes -= cost(removed) }
        }
    }

    package mutating func removeAll() {
        values.removeAll()
        order.removeAll()
        bytes = 0
    }
}
