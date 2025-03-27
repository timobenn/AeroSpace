// TODO: justified in own file?
public enum CardinalOrDfsDirection: Equatable, Sendable {
    case dfs(DfsRelative)
    case cardinal(CardinalDirection)
}
