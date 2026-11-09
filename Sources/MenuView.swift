import SwiftUI

struct MenuView: View {
    @EnvironmentObject private var model: AppModel
    @State private var zoomDraft: Double = 1.0
    @State private var draggingZoom = false
    @State private var showWhiteBalance = false
    @AppStorage(AppDelegate.menuBarIconKey) private var showMenuBarIcon = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header
            if model.displays.count > 1 { displayPicker }
            if model.selected == nil {
                emptyState
            } else {
                sizeCard
                colourCard
            }
            if let error = model.lastError {
                Label(error, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }
            footer
        }
        .padding(14)
        .frame(width: 340)
        // A solid backdrop: the default see-through menu material lets the windows behind blur
        // into the text.
        .background(Color(nsColor: .windowBackgroundColor))
        .onAppear { zoomDraft = model.profile.zoom }
        .onChange(of: model.profile.zoom) { _, new in if !draggingZoom { zoomDraft = new } }
        .onChange(of: model.selectedKey) { _, _ in zoomDraft = model.profile.zoom }
    }

    // MARK: - Header

    private var header: some View {
        HStack(spacing: 10) {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(LinearGradient(colors: [Color(red: 0.25, green: 0.55, blue: 1.0), Color(red: 0.55, green: 0.35, blue: 0.95)],
                                     startPoint: .topLeading, endPoint: .bottomTrailing))
                .frame(width: 32, height: 32)
                .overlay(
                    Image(systemName: "sparkle.magnifyingglass")
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(.white)
                )
                .shadow(color: .black.opacity(0.15), radius: 2, y: 1)

            VStack(alignment: .leading, spacing: 1) {
                Text("Clarity")
                    .font(.system(size: 15, weight: .bold))
                if let display = model.selected {
                    Text(verbatim: "\(display.name) · \(display.nativeWidth) × \(display.nativeHeight)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    Text("No external monitor").font(.caption).foregroundStyle(.secondary)
                }
            }

            Spacer()

            if model.selected != nil { statusPill }
        }
        .padding(.bottom, 2)
    }

    private var statusPill: some View {
        let zoom = model.profile.zoom
        let scaled = zoom > 1.0001
        return Text(verbatim: scaled ? "\(Int((zoom * 100).rounded()))% · Sharp" : "Native")
            .font(.caption.weight(.semibold))
            .padding(.horizontal, 9)
            .padding(.vertical, 4)
            .foregroundStyle(scaled ? Color.white : Color.secondary)
            .background(scaled ? AnyShapeStyle(Color.accentColor) : AnyShapeStyle(Color.primary.opacity(0.08)), in: Capsule())
    }

    private var displayPicker: some View {
        Picker("Monitor", selection: Binding(get: { model.selected?.key }, set: { model.selectedKey = $0 })) {
            ForEach(model.displays) { Text($0.name).tag(Optional($0.key)) }
        }
        .pickerStyle(.segmented)
        .labelsHidden()
    }

    private var emptyState: some View {
        Text("Connect an external monitor to adjust its size and colour.")
            .font(.callout)
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.vertical, 8)
    }

    // MARK: - Size

    private var sizeCard: some View {
        Card(title: "Size", systemImage: "arrow.up.left.and.arrow.down.right") {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(verbatim: zoomDraft <= 1.0001 ? "Native" : "\(Int((zoomDraft * 100).rounded()))%")
                    .font(.system(size: 22, weight: .semibold, design: .rounded))
                    .monospacedDigit()
                Text(verbatim: "looks like \(model.looksLike(zoom: zoomDraft))")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
                Spacer()
                if model.busy { ProgressView().controlSize(.small) }
            }

            Slider(value: Binding(get: { zoomDraft }, set: { zoomDraft = ($0 / 0.05).rounded() * 0.05 }),
                   in: model.zoomRange) { editing in
                draggingZoom = editing
                if !editing { model.setZoom(zoomDraft) }
            }
            .disabled(model.busy)

            HStack(spacing: 5) {
                ForEach(model.zoomPresets, id: \.self) { preset in
                    Chip(label: preset <= 1.0001 ? "Native" : "\(Int((preset * 100).rounded()))%",
                         selected: abs(model.profile.zoom - preset) < 0.001) {
                        zoomDraft = preset
                        model.setZoom(preset)
                    }
                }
            }
            .disabled(model.busy)

            HStack {
                VStack(alignment: .leading, spacing: 1) {
                    Text("Main display while scaled").font(.callout)
                    Text("Needed for swiping between desktops on this monitor.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Toggle("Main display while scaled",
                       isOn: Binding(get: { model.profile.makeMain }, set: { model.setMakeMain($0) }))
                    .toggleStyle(.switch)
                    .controlSize(.small)
                    .labelsHidden()
            }
            .padding(.top, 2)

            Text(model.profile.zoom > 1.0001
                 ? "Quitting Clarity returns the monitor to native size."
                 : "Everything bigger, drawn at 2× and shrunk to fit, so text stays sharp.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: - Colour

    private var colourCard: some View {
        Card(title: "Colour", systemImage: "paintpalette") {
            HStack(spacing: 5) {
                Chip(label: "Neutral", selected: model.profile.color.isNeutral) { model.resetColor() }
                Chip(label: "10% warmer", selected: isWarmth(10)) { setWarmth(10) }
                Chip(label: "Evening", selected: isWarmth(30)) { setWarmth(30) }
            }

            VStack(spacing: 10) {
                VStack(spacing: 3) {
                    AdjustRow(title: "Warmth", value: warmthLabel, range: -30...40, step: 1,
                              binding: Binding(get: { warmth }, set: { setWarmth($0) }),
                              tint: warmth > 0.5 ? .orange : (warmth < -0.5 ? .blue : .gray))
                    // A colour key under the warmth slider: cooler on the left, warmer on the right.
                    LinearGradient(colors: [Color(red: 0.6, green: 0.75, blue: 1), .white, Color(red: 1, green: 0.7, blue: 0.4)],
                                   startPoint: .leading, endPoint: .trailing)
                        .frame(height: 3)
                        .clipShape(Capsule())
                        .padding(.horizontal, 2)
                    HStack {
                        Text("Cooler"); Spacer(); Text("Warmer")
                    }
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                }
                AdjustRow(title: "Brightness", value: percent(model.profile.color.brightness), range: 0.3...1, step: 0.01,
                          binding: colorBinding(\.brightness))
                AdjustRow(title: "Contrast", value: percent(model.profile.color.contrast), range: 0.7...1.3, step: 0.01,
                          binding: colorBinding(\.contrast))
                AdjustRow(title: "Gamma", value: String(format: "%.2f", model.profile.color.gamma), range: 1.8...2.6, step: 0.05,
                          binding: colorBinding(\.gamma))
            }

            DisclosureGroup(isExpanded: $showWhiteBalance) {
                VStack(spacing: 10) {
                    AdjustRow(title: "Red", value: percent(model.profile.color.red), range: 0.5...1, step: 0.01,
                              binding: colorBinding(\.red), tint: .red)
                    AdjustRow(title: "Green", value: percent(model.profile.color.green), range: 0.5...1, step: 0.01,
                              binding: colorBinding(\.green), tint: .green)
                    AdjustRow(title: "Blue", value: percent(model.profile.color.blue), range: 0.5...1, step: 0.01,
                              binding: colorBinding(\.blue), tint: .blue)
                }
                .padding(.top, 6)
            } label: {
                Text("White balance").font(.callout)
            }
        }
    }

    private var warmth: Double { (6500 / model.profile.color.temperature - 1) * 100 }

    private var warmthLabel: String {
        let w = Int(warmth.rounded())
        let kelvin = Int((model.profile.color.temperature / 50).rounded() * 50)
        if w == 0 { return "Neutral · 6500 K" }
        return "\(abs(w))% \(w > 0 ? "warmer" : "cooler") · \(kelvin) K"
    }

    private func isWarmth(_ percent: Double) -> Bool {
        abs(warmth - percent) < 0.5
    }

    private func setWarmth(_ percent: Double) {
        model.setColor { $0.temperature = ColorSettings.temperature(forWarmthPercent: percent) }
    }

    private func colorBinding(_ path: WritableKeyPath<ColorSettings, Double>) -> Binding<Double> {
        Binding(get: { model.profile.color[keyPath: path] },
                set: { value in model.setColor { $0[keyPath: path] = value } })
    }

    private func percent(_ value: Double) -> String { "\(Int((value * 100).rounded()))%" }

    // MARK: - Footer

    private var footer: some View {
        VStack(spacing: 10) {
            Divider()
            HStack {
                Text("Open at login").font(.callout)
                Spacer()
                Toggle("Open at login", isOn: Binding(get: { model.launchAtLogin }, set: { model.setLaunchAtLogin($0) }))
                    .toggleStyle(.switch)
                    .controlSize(.small)
                    .labelsHidden()
            }
            HStack {
                VStack(alignment: .leading, spacing: 1) {
                    Text("Menu bar icon").font(.callout)
                    Text("Without it, open Clarity again to get this window back.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Toggle("Menu bar icon", isOn: $showMenuBarIcon)
                    .toggleStyle(.switch)
                    .controlSize(.small)
                    .labelsHidden()
            }
            HStack {
                Button("Turn everything off") { model.revertAll(); zoomDraft = 1 }
                Spacer()
                Button("Quit Clarity") { NSApp.terminate(nil) }
                    .keyboardShortcut("q")
            }
        }
    }
}

// MARK: - Building blocks

private struct Card<Content: View>: View {
    let title: String
    let systemImage: String
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label(title, systemImage: systemImage)
                .font(.caption.weight(.semibold))
                .textCase(.uppercase)
                .foregroundStyle(.secondary)
            content
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.primary.opacity(0.045), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(Color.primary.opacity(0.07)))
    }
}

private struct Chip: View {
    let label: String
    let selected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(label)
                .font(.caption.weight(selected ? .semibold : .medium))
                .lineLimit(1)
                .minimumScaleFactor(0.85)
                .foregroundStyle(selected ? Color.white : Color.primary)
                .padding(.horizontal, 4)
                .padding(.vertical, 5)
                .frame(maxWidth: .infinity)
                .background(selected ? Color.accentColor : Color.primary.opacity(0.07), in: Capsule())
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
    }
}

/// Title and value on one line, slider underneath. Snaps to `step` without drawing tick marks.
private struct AdjustRow: View {
    let title: String
    let value: String
    let range: ClosedRange<Double>
    let step: Double
    let binding: Binding<Double>
    var tint: Color = .accentColor

    var body: some View {
        VStack(spacing: 2) {
            HStack {
                Text(title).font(.callout)
                Spacer()
                Text(value).font(.callout.monospacedDigit()).foregroundStyle(.secondary)
            }
            Slider(value: Binding(get: { binding.wrappedValue },
                                  set: { binding.wrappedValue = ($0 / step).rounded() * step }),
                   in: range)
                .tint(tint)
                .controlSize(.small)
        }
    }
}
