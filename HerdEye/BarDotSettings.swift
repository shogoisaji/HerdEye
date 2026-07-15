import Foundation
import Observation
import SwiftUI

/// Dot shape.
enum DotShape: String, CaseIterable, Codable {
    case circle, square

    var label: String {
        switch self {
        case .circle: "Circle"
        case .square: "Square"
        }
    }
}

/// Codable color representation. Stores RGB components in sRGB to stabilize
/// round-tripping with ColorPicker.
struct DotColor: Codable, Equatable, Hashable {
    var red: Double
    var green: Double
    var blue: Double

    var color: Color {
        Color(.sRGB, red: red, green: green, blue: blue, opacity: 1)
    }

    var nsColor: NSColor {
        NSColor(srgbRed: red, green: green, blue: blue, alpha: 1)
    }

    init(red: Double, green: Double, blue: Double) {
        self.red = red
        self.green = green
        self.blue = blue
    }

    init(_ color: Color) {
        let nsColor = NSColor(color).usingColorSpace(.sRGB) ?? .black
        self.red = Double(nsColor.redComponent)
        self.green = Double(nsColor.greenComponent)
        self.blue = Double(nsColor.blueComponent)
    }
}

/// Per-state dot display settings. Outline and fill colors are independent.
struct DotAppearance: Codable, Equatable {
    var shape: DotShape
    var outline: Bool
    var outlineColor: DotColor
    var fill: Bool
    var fillColor: DotColor

    static let defaultIdle = DotAppearance(
        shape: .circle, outline: true, outlineColor: DotColor(red: 0.55, green: 0.55, blue: 0.58),
        fill: false, fillColor: DotColor(red: 0.55, green: 0.55, blue: 0.58))
    static let defaultWorking = DotAppearance(
        shape: .square, outline: false, outlineColor: DotColor(red: 0.05, green: 0.6, blue: 1.0),
        fill: true, fillColor: DotColor(red: 0.05, green: 0.6, blue: 1.0))
    static let defaultBlocked = DotAppearance(
        shape: .square, outline: false, outlineColor: DotColor(red: 1.0, green: 0.15, blue: 0.2),
        fill: true, fillColor: DotColor(red: 1.0, green: 0.15, blue: 0.2))
    static let defaultDone = DotAppearance(
        shape: .square, outline: false, outlineColor: DotColor(red: 0.2, green: 1.0, blue: 0.3),
        fill: true, fillColor: DotColor(red: 0.2, green: 1.0, blue: 0.3))
    static let defaultUnknown = DotAppearance(
        shape: .circle, outline: true, outlineColor: DotColor(red: 0.55, green: 0.55, blue: 0.58),
        fill: false, fillColor: DotColor(red: 0.55, green: 0.55, blue: 0.58))
}

/// Persists per-state menu bar dot display settings.
/// Values are stored as JSON in UserDefaults.
@Observable @MainActor
final class BarDotSettingsStore {
    var idle: DotAppearance {
        didSet { schedulePersist() }
    }
    var working: DotAppearance {
        didSet { schedulePersist() }
    }
    var blocked: DotAppearance {
        didSet { schedulePersist() }
    }
    var done: DotAppearance {
        didSet { schedulePersist() }
    }
    var unknown: DotAppearance {
        didSet { schedulePersist() }
    }

    private var persistTask: Task<Void, Never>?

    init() {
        let defaults = UserDefaults.standard
        if let data = defaults.data(forKey: Keys.settings),
           let loaded = try? JSONDecoder().decode(StoredSettings.self, from: data) {
            self.idle = loaded.idle
            self.working = loaded.working
            self.blocked = loaded.blocked
            self.done = loaded.done
            self.unknown = loaded.unknown
        } else {
            self.idle = .defaultIdle
            self.working = .defaultWorking
            self.blocked = .defaultBlocked
            self.done = .defaultDone
            self.unknown = .defaultUnknown
        }
    }

    func appearance(for state: AgentState) -> DotAppearance {
        switch state {
        case .idle:     idle
        case .working:  working
        case .blocked:  blocked
        case .done:     done
        case .unknown:  unknown
        }
    }

    /// Debounce persistence to avoid writing every frame while dragging ColorPicker,
    /// saving once 300 ms after the last change.
    private func schedulePersist() {
        persistTask?.cancel()
        persistTask = Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(300))
            guard !Task.isCancelled else { return }
            persist()
        }
    }

    private func persist() {
        let stored = StoredSettings(
            idle: idle,
            working: working,
            blocked: blocked,
            done: done,
            unknown: unknown
        )
        if let data = try? JSONEncoder().encode(stored) {
            UserDefaults.standard.set(data, forKey: Keys.settings)
        }
    }

    private struct StoredSettings: Codable {
        let idle: DotAppearance
        let working: DotAppearance
        let blocked: DotAppearance
        let done: DotAppearance
        let unknown: DotAppearance

        init(
            idle: DotAppearance,
            working: DotAppearance,
            blocked: DotAppearance,
            done: DotAppearance,
            unknown: DotAppearance
        ) {
            self.idle = idle
            self.working = working
            self.blocked = blocked
            self.done = done
            self.unknown = unknown
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            self.idle = try container.decode(DotAppearance.self, forKey: .idle)
            self.working = try container.decode(DotAppearance.self, forKey: .working)
            self.blocked = try container.decode(DotAppearance.self, forKey: .blocked)
            self.done = try container.decode(DotAppearance.self, forKey: .done)
            self.unknown = try container.decode(DotAppearance.self, forKey: .unknown)
        }
    }

    private enum Keys {
        static let settings = "barDotSettings"
    }
}
