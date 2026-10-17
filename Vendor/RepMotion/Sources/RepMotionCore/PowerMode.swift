public enum PowerMode: String, CaseIterable, Identifiable, Sendable {
    case rollingAvg
    case rollingMax
    case absolute

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .rollingAvg: return "Rolling Avg"
        case .rollingMax: return "Rolling Max"
        case .absolute: return "Absolute (g)"
        }
    }
}
