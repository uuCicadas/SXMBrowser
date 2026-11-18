import Foundation

public enum FileSortCriterion: Sendable {
    case name
    case modifiedTime
    case recordedTime
}

public struct FileSortValue: Sendable {
    public let identity: String
    public let filename: String
    public let modifiedTime: Date
    public let recordedTime: Date?

    public init(
        identity: String,
        filename: String,
        modifiedTime: Date,
        recordedTime: Date?
    ) {
        self.identity = identity
        self.filename = filename
        self.modifiedTime = modifiedTime
        self.recordedTime = recordedTime
    }
}

public enum FileSortComparator {
    public static func orderedBefore(
        _ lhs: FileSortValue,
        _ rhs: FileSortValue,
        criterion: FileSortCriterion,
        ascending: Bool
    ) -> Bool {
        guard lhs.identity != rhs.identity else { return false }

        if criterion == .recordedTime {
            switch (lhs.recordedTime, rhs.recordedTime) {
            case (nil, nil):
                break
            case (nil, _?):
                return false
            case (_?, nil):
                return true
            case (let lhsDate?, let rhsDate?) where lhsDate != rhsDate:
                return ascending ? lhsDate < rhsDate : lhsDate > rhsDate
            default:
                break
            }
        }

        let primaryResult: ComparisonResult
        switch criterion {
        case .name:
            primaryResult = lhs.filename.localizedStandardCompare(rhs.filename)
        case .modifiedTime:
            primaryResult = compare(lhs.modifiedTime, rhs.modifiedTime)
        case .recordedTime:
            primaryResult = .orderedSame
        }
        if primaryResult != .orderedSame {
            return ascending
                ? primaryResult == .orderedAscending
                : primaryResult == .orderedDescending
        }

        let filenameResult = lhs.filename.localizedStandardCompare(rhs.filename)
        if filenameResult != .orderedSame {
            return filenameResult == .orderedAscending
        }
        return lhs.identity < rhs.identity
    }

    private static func compare(_ lhs: Date, _ rhs: Date) -> ComparisonResult {
        if lhs < rhs { return .orderedAscending }
        if lhs > rhs { return .orderedDescending }
        return .orderedSame
    }
}
