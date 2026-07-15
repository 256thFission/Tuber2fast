import Foundation

enum DevelopmentScenario: String {
    case blankCanvas = "blank-canvas"
    case fakePin = "fake-pin"
    case multiPin = "multi-pin"

    static var current: Self {
#if DEBUG
        let process = ProcessInfo.processInfo
        if let value = process.environment["TUBER_SCENARIO"], let scenario = Self(rawValue: value) {
            return scenario
        }
        if let index = process.arguments.firstIndex(of: "--scenario"),
           process.arguments.indices.contains(index + 1),
           let scenario = Self(rawValue: process.arguments[index + 1]) {
            return scenario
        }
#endif
        return .blankCanvas
    }

    var displayName: String { rawValue }

    var pins: [Pin] {
        switch self {
        case .blankCanvas: []
        case .fakePin:
            [Pin(id: UUID(uuidString: "11111111-1111-1111-1111-111111111111")!, pagePosition: CGPoint(x: 0.62, y: 0.34), title: "Key idea", detail: "This Pin is deterministic and page-normalized.")]
        case .multiPin:
            [
                Pin(id: UUID(uuidString: "22222222-2222-2222-2222-222222222222")!, pagePosition: CGPoint(x: 0.24, y: 0.22), title: "Start here", detail: "The first known spatial target."),
                Pin(id: UUID(uuidString: "33333333-3333-3333-3333-333333333333")!, pagePosition: CGPoint(x: 0.69, y: 0.49), title: "Check this", detail: "The second known spatial target."),
                Pin(id: UUID(uuidString: "44444444-4444-4444-4444-444444444444")!, pagePosition: CGPoint(x: 0.40, y: 0.76), title: "Related", detail: "The third known spatial target.")
            ]
        }
    }

    var penFixture: PenFixture? {
#if DEBUG
        return PenFixtureStore.loadRequestedFixture()
#else
        return nil
#endif
    }
}

