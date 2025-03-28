// TODO: justified in own file?
public enum CardinalOrDfsDirection: Equatable, Sendable {
    case dfs(DfsRelative)
    case cardinal(CardinalDirection)
}

extension CardinalOrDfsDirection {
    static var unionLiteral: String {
        "(left|down|up|right|dfs-next|dfs-prev)"
    }
}
