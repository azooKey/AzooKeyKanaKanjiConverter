enum SurfacePiece: Sendable, Equatable, Hashable {
    case character(Character)
    case surfaceSeparator

    var character: Character? {
        switch self {
        case .character(let c):
            return c
        default:
            return nil
        }
    }
}

extension SurfacePiece: ExpressibleByExtendedGraphemeClusterLiteral {
    public init(extendedGraphemeClusterLiteral value: Character) {
        self = .character(value)
    }

    public init(unicodeScalarLiteral value: UnicodeScalar) {
        self = .character(Character(value))
    }
}
