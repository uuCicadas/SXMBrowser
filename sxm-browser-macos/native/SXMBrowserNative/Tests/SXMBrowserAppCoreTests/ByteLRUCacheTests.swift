import Testing
@testable import SXMBrowserAppCore

@Test
func cacheHitRefreshesRecency() {
    let cache = ByteLRUCache<String, Int>(byteLimit: 2)
    #expect(cache.insert(1, forKey: "a", cost: 1))
    #expect(cache.insert(2, forKey: "b", cost: 1))

    #expect(cache.value(forKey: "a") == 1)
    #expect(cache.keysFromLeastToMostRecent == ["b", "a"])

    #expect(cache.insert(3, forKey: "c", cost: 1))
    #expect(!cache.contains("b"))
    #expect(cache.value(forKey: "a") == 1)
    #expect(cache.value(forKey: "c") == 3)
    #expect(cache.totalCost == 2)
}

@Test
func replacementUsesNewCostAndBecomesMostRecent() {
    let cache = ByteLRUCache<String, String>(byteLimit: 10)
    #expect(cache.insert("old-a", forKey: "a", cost: 6))
    #expect(cache.insert("b", forKey: "b", cost: 4))

    #expect(cache.insert("new-a", forKey: "a", cost: 2))
    #expect(cache.count == 2)
    #expect(cache.totalCost == 6)
    #expect(cache.cost(forKey: "a") == 2)
    #expect(cache.keysFromLeastToMostRecent == ["b", "a"])

    #expect(cache.insert("c", forKey: "c", cost: 5))
    #expect(!cache.contains("b"))
    #expect(cache.value(forKey: "a") == "new-a")
    #expect(cache.value(forKey: "c") == "c")
    #expect(cache.totalCost == 7)
}

@Test
func removalAndClearRestoreAccounting() {
    let cache = ByteLRUCache<Int, String>(byteLimit: 20)
    #expect(cache.insert("one", forKey: 1, cost: 7))
    #expect(cache.insert("two", forKey: 2, cost: 8))

    #expect(cache.removeValue(forKey: 1) == "one")
    #expect(cache.removeValue(forKey: 1) == nil)
    #expect(cache.totalCost == 8)
    #expect(cache.count == 1)

    cache.removeAll(keepingCapacity: true)
    #expect(cache.isEmpty)
    #expect(cache.totalCost == 0)
    #expect(cache.keysFromLeastToMostRecent.isEmpty)
    #expect(cache.value(forKey: 2) == nil)
}

@Test
func negativeCostIsRejectedWithoutChangingExistingEntry() {
    let cache = ByteLRUCache<String, String>(byteLimit: 8)
    #expect(cache.insert("original", forKey: "key", cost: 3))

    #expect(!cache.insert("invalid", forKey: "key", cost: -1))
    #expect(cache.value(forKey: "key") == "original")
    #expect(cache.cost(forKey: "key") == 3)
    #expect(cache.totalCost == 3)
    #expect(cache.count == 1)
}

@Test
func zeroCostEntriesAreSupportedAtZeroLimit() {
    let cache = ByteLRUCache<String, Int>(byteLimit: 0)
    #expect(cache.insert(1, forKey: "a", cost: 0))
    #expect(cache.insert(2, forKey: "b", cost: 0))

    #expect(cache.count == 2)
    #expect(cache.totalCost == 0)
    #expect(cache.value(forKey: "a") == 1)
    #expect(cache.value(forKey: "b") == 2)
    #expect(!cache.insert(3, forKey: "c", cost: 1))
    #expect(!cache.contains("c"))
}

@Test
func oversizedEntryIsNotCachedOrAllowedToLeaveStaleReplacement() {
    let cache = ByteLRUCache<String, Int>(byteLimit: 5)
    #expect(cache.insert(1, forKey: "a", cost: 3))
    #expect(cache.insert(2, forKey: "b", cost: 2))

    #expect(!cache.insert(3, forKey: "c", cost: 6))
    #expect(cache.count == 2)
    #expect(cache.totalCost == 5)

    #expect(!cache.insert(9, forKey: "a", cost: 6))
    #expect(!cache.contains("a"))
    #expect(cache.value(forKey: "b") == 2)
    #expect(cache.totalCost == 2)
}

@Test
func repeatedEvictionNeverExceedsByteLimit() {
    let cache = ByteLRUCache<Int, Int>(byteLimit: 7)

    for key in 0..<100 {
        #expect(cache.insert(key, forKey: key, cost: 3))
        #expect(cache.totalCost <= cache.byteLimit)
        #expect(cache.count <= 2)
    }

    #expect(cache.totalCost == 6)
    #expect(cache.keysFromLeastToMostRecent == [98, 99])
}

@Test
func matrixBudgetUsesExactlyOneEighthUpTo512MiB() {
    let mib = UInt64(1_024 * 1_024)

    #expect(MatrixCacheBudget.byteLimit(physicalMemoryBytes: 0) == 0)
    #expect(MatrixCacheBudget.byteLimit(physicalMemoryBytes: 7) == 0)
    #expect(MatrixCacheBudget.byteLimit(physicalMemoryBytes: 8) == 1)
    #expect(
        MatrixCacheBudget.byteLimit(physicalMemoryBytes: 2 * 1_024 * mib)
            == 256 * 1_024 * 1_024
    )
    #expect(
        MatrixCacheBudget.byteLimit(physicalMemoryBytes: 4 * 1_024 * mib)
            == MatrixCacheBudget.maximumBytes
    )
    #expect(
        MatrixCacheBudget.byteLimit(physicalMemoryBytes: 64 * 1_024 * mib)
            == MatrixCacheBudget.maximumBytes
    )
}

@Test
func matrixBudgetConversionIsSafeForLargestPhysicalMemoryValue() {
    let result = MatrixCacheBudget.byteLimit(
        physicalMemoryBytes: UInt64.max
    )

    #expect(result == MatrixCacheBudget.maximumBytes)
    #expect(result >= 0)
    #expect(result <= Int.max)
}
