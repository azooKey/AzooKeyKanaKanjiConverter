public enum InputPiece: Sendable, Equatable, Hashable {
    case character(Character)
    case compositionSeparator
}

extension InputPiece: ExpressibleByExtendedGraphemeClusterLiteral {
    public init(extendedGraphemeClusterLiteral value: Character) {
        self = .character(value)
    }
    
    public init(unicodeScalarLiteral value: UnicodeScalar) {
        self = .character(Character(value))
    }
}
