public import struct Foundation.URL

public enum InputTableID: Sendable, Equatable, Hashable {
    case defaultRomanToKana
    case defaultAZIK
    case empty
    case custom(URL)
}
