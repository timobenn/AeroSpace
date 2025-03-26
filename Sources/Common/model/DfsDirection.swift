public enum DfsRelative: String, CaseIterable, Equatable, Sendable {
    case dfsNext, dfsPrev
}

extension DfsRelative {
    // TODO: need this? public var orientation: Orientation { self == .up || self == .down ? .v : .h }
    public var isPositive: Bool { self == .dfsNext }
    public var opposite: DfsRelative {
        return switch self {
        case .dfsNext: .dfsPrev
        case .dfsPrev: .dfsNext
        }
    }
    public var focusOffset: Int { isPositive ? 1 : -1 }
    public var insertionOffset: Int { isPositive ? 1 : 0 }
}
