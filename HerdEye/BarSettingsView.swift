import SwiftUI

/// Settings window for dot display. Allows changing the appearance for each state.
struct BarSettingsView: View {
    @Bindable var settings: BarDotSettingsStore

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Text("Dot Appearance")
                    .font(.headline)

                ForEach(AgentState.allCases, id: \.self) { state in
                    appearanceRow(for: state)
                }

                Divider()

                Button("Reset to Defaults") {
                    settings.idle = .defaultIdle
                    settings.working = .defaultWorking
                    settings.blocked = .defaultBlocked
                    settings.done = .defaultDone
                    settings.unknown = .defaultUnknown
                }
            }
            .padding(20)
        }
        .frame(width: 520, height: 520)
    }

    /// Get bindings to each state's DotAppearance using @Bindable's $ syntax.
    private func appearanceBinding(for state: AgentState) -> Binding<DotAppearance> {
        switch state {
        case .idle:     $settings.idle
        case .working:  $settings.working
        case .blocked:  $settings.blocked
        case .done:     $settings.done
        case .unknown:  $settings.unknown
        }
    }

    @ViewBuilder
    private func appearanceRow(for state: AgentState) -> some View {
        let appearance = settings.appearance(for: state)
        let binding = appearanceBinding(for: state)
        VStack(alignment: .leading, spacing: 10) {
            // Header: preview + state name + shape.
            HStack(spacing: 10) {
                DotPreview(appearance: appearance, size: 18)
                Text(stateLabel(state))
                    .font(.subheadline)
                Spacer()
                Picker("Shape", selection: binding.shape) {
                    ForEach(DotShape.allCases, id: \.self) { shape in
                        Text(shape.label).tag(shape)
                    }
                }
                .pickerStyle(.segmented)
                .frame(width: 160)
                .labelsHidden()
            }

            // Outline row.
            HStack(spacing: 10) {
                Toggle("Outline", isOn: binding.outline)
                    .toggleStyle(.checkbox)
                    .frame(width: 100, alignment: .leading)
                StableColorPicker(
                    label: "Outline Color",
                    initialColor: appearance.outlineColor.color
                ) { newColor in
                    binding.wrappedValue.outlineColor = DotColor(newColor)
                }
                Spacer()
            }

            // Fill row.
            HStack(spacing: 10) {
                Toggle("Fill", isOn: binding.fill)
                    .toggleStyle(.checkbox)
                    .frame(width: 100, alignment: .leading)
                StableColorPicker(
                    label: "Fill Color",
                    initialColor: appearance.fillColor.color
                ) { newColor in
                    binding.wrappedValue.fillColor = DotColor(newColor)
                }
                Spacer()
            }
        }
        .padding(12)
        .background(Color(nsColor: .controlBackgroundColor))
        .cornerRadius(8)
    }

    private func stateLabel(_ state: AgentState) -> String {
        switch state {
        case .idle: "Idle"
        case .working: "Working"
        case .blocked: "Blocked"
        case .done: "Done"
        case .unknown: "Unknown"
        }
    }
}

// MARK: - StableColorPicker

/// Bind ColorPicker to local @State and write changes back to the store via a callback.
/// This prevents ColorPicker from unexpectedly reverting due to store feedback.
/// Refresh when the store's color changes externally by using id().
struct StableColorPicker: View {
    let label: String
    let initialColor: Color
    let onChange: (Color) -> Void

    @State private var localColor: Color
    @State private var lastExternalColor: Color

    init(label: String, initialColor: Color, onChange: @escaping (Color) -> Void) {
        self.label = label
        self.initialColor = initialColor
        self.onChange = onChange
        self._localColor = State(initialValue: initialColor)
        self._lastExternalColor = State(initialValue: initialColor)
    }

    var body: some View {
        ColorPicker(selection: $localColor) {
            Text(label)
                .font(.caption)
        }
        .onChange(of: initialColor) { _, newExternal in
            // Update localColor only for external changes, such as Reset to Defaults.
            // For user-driven onChange, localColor is already current and needs no update.
            if newExternal != lastExternalColor {
                localColor = newExternal
                lastExternalColor = newExternal
            }
        }
        .onChange(of: localColor) { oldColor, newColor in
            // Write back to the store only when the user changes ColorPicker.
            // Ignore updates originating from externalColor using lastExternalColor.
            if newColor != lastExternalColor {
                onChange(newColor)
                lastExternalColor = newColor
            }
        }
    }
}

// MARK: - DotPreview

/// Dot preview in the settings screen, reflecting shape, outline color, and fill color.
struct DotPreview: View {
    let appearance: DotAppearance
    let size: CGFloat

    var body: some View {
        shape
            .fill(appearance.fill ? appearance.fillColor.color : .clear)
            .overlay(
                shape
                    .stroke(appearance.outline ? appearance.outlineColor.color : .clear, lineWidth: 1.5)
            )
            .frame(width: size, height: size)
    }

    private var shape: AnyShape {
        switch appearance.shape {
        case .circle: AnyShape(Circle())
        case .square: AnyShape(RoundedRectangle(cornerRadius: 2))
        }
    }
}
