import Foundation

/// A small actor-confined LRU cache with optional per-entry expiration.
/// This type is intentionally not synchronized; callers keep it inside their actor.
nonisolated struct BoundedLRUCache<Key: Hashable, Value> {
    private struct Entry {
        var value: Value
        var expiresAt: Date?
        var previousKey: Key?
        var nextKey: Key?
    }

    let capacity: Int

    private var entries: [Key: Entry] = [:]
    private var mostRecentlyUsedKey: Key?
    private var leastRecentlyUsedKey: Key?

    init(capacity: Int) {
        precondition(capacity > 0, "BoundedLRUCache capacity must be positive")
        self.capacity = capacity
        entries.reserveCapacity(capacity)
    }

    var count: Int {
        entries.count
    }

    mutating func value(forKey key: Key, now: Date = Date()) -> Value? {
        guard let entry = entries[key] else { return nil }
        if let expiresAt = entry.expiresAt, expiresAt <= now {
            removeValue(forKey: key)
            return nil
        }

        moveToMostRecentlyUsed(key)
        return entries[key]?.value
    }

    mutating func insert(_ value: Value, forKey key: Key, expiresAt: Date? = nil) {
        if var existing = entries[key] {
            existing.value = value
            existing.expiresAt = expiresAt
            entries[key] = existing
            moveToMostRecentlyUsed(key)
            return
        }

        let previousMostRecent = mostRecentlyUsedKey
        entries[key] = Entry(
            value: value,
            expiresAt: expiresAt,
            previousKey: nil,
            nextKey: previousMostRecent
        )

        if let previousMostRecent, var entry = entries[previousMostRecent] {
            entry.previousKey = key
            entries[previousMostRecent] = entry
        } else {
            leastRecentlyUsedKey = key
        }
        mostRecentlyUsedKey = key

        if entries.count > capacity, let leastRecentlyUsedKey {
            removeValue(forKey: leastRecentlyUsedKey)
        }
    }

    mutating func removeValue(forKey key: Key) {
        guard let entry = entries.removeValue(forKey: key) else { return }

        if let previousKey = entry.previousKey, var previous = entries[previousKey] {
            previous.nextKey = entry.nextKey
            entries[previousKey] = previous
        } else {
            mostRecentlyUsedKey = entry.nextKey
        }

        if let nextKey = entry.nextKey, var next = entries[nextKey] {
            next.previousKey = entry.previousKey
            entries[nextKey] = next
        } else {
            leastRecentlyUsedKey = entry.previousKey
        }
    }

    mutating func removeAll(keepingCapacity: Bool = true) {
        entries.removeAll(keepingCapacity: keepingCapacity)
        mostRecentlyUsedKey = nil
        leastRecentlyUsedKey = nil
    }

    private mutating func moveToMostRecentlyUsed(_ key: Key) {
        guard mostRecentlyUsedKey != key, var entry = entries[key] else { return }

        if let previousKey = entry.previousKey, var previous = entries[previousKey] {
            previous.nextKey = entry.nextKey
            entries[previousKey] = previous
        }
        if let nextKey = entry.nextKey, var next = entries[nextKey] {
            next.previousKey = entry.previousKey
            entries[nextKey] = next
        } else {
            leastRecentlyUsedKey = entry.previousKey
        }

        let previousMostRecent = mostRecentlyUsedKey
        entry.previousKey = nil
        entry.nextKey = previousMostRecent
        entries[key] = entry

        if let previousMostRecent, var previous = entries[previousMostRecent] {
            previous.previousKey = key
            entries[previousMostRecent] = previous
        }
        mostRecentlyUsedKey = key
        if leastRecentlyUsedKey == nil {
            leastRecentlyUsedKey = key
        }
    }
}
