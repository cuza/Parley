import SwiftUI

/// Settings ▸ Appearance: light or dark, wallpaper and bubble colour per appearance, message style, window tabs.
struct AppearanceSettings: View {
    @AppStorage("timelineStyle") private var style = TimelineStyle.bubbles
    @AppStorage(AppearanceMode.key) private var appearance = AppearanceMode.auto
    @AppStorage(Wallpaper.key(dark: false)) private var wallpaper = Wallpaper.none
    @AppStorage(Wallpaper.key(dark: true)) private var darkWallpaper = Wallpaper.none
    @AppStorage(Wallpaper.doodlesKey) private var doodles = true
    @AppStorage(BubblePalette.colorKey(dark: false)) private var bubbleColor = ""
    @AppStorage(BubblePalette.colorKey(dark: true)) private var darkBubbleColor = ""
    @AppStorage(ConversationTabs.key) private var windowsAsTabs = true
    @AppStorage(TextSize.key) private var textScale = 1.0  // follows View ▸ Bigger and Smaller too
    /// One appearance's wallpaper and bubble colour.
    private func look(_ title: String, wallpaper: Binding<Wallpaper>, bubble: Binding<String>) -> some View {
        LabeledContent(title) {
            HStack {
                Picker("Wallpaper", selection: wallpaper) {
                    ForEach(Wallpaper.allCases, id: \.self) {
                        Text($0 == .none ? "No Wallpaper" : $0.rawValue.capitalized).tag($0)
                    }
                }
                .labelsHidden().fixedSize()
                BubbleColorPicker(hex: bubble)
                Button("Reset") { bubble.wrappedValue = "" }.disabled(bubble.wrappedValue.isEmpty)
                    .help("Use the accent color").accessibilityLabel("Use the accent color")
            }
        }
    }
    var body: some View {
        Form {
            Section {
                Picker("Appearance", selection: $appearance) {
                    Text("Auto").tag(AppearanceMode.auto)
                    Text("Light").tag(AppearanceMode.light)
                    Text("Dark").tag(AppearanceMode.dark)
                }
                .pickerStyle(.segmented)
                .onChange(of: appearance) { AppearanceMode.apply() }
            }
            Section {
                look("Light mode", wallpaper: $wallpaper, bubble: $bubbleColor)
                look("Dark mode", wallpaper: $darkWallpaper, bubble: $darkBubbleColor)
                Toggle("Doodles over the wallpaper", isOn: $doodles).disabled(
                    wallpaper == .none && darkWallpaper == .none)
            } header: {
                Text("Wallpaper and bubbles")
            } footer: {
                SettingsFooter("Text on your bubbles turns white or black, whichever reads better on the colour.")
            }
            Section {
                Picker("Message style", selection: $style) {
                    Text("Bubbles").tag(TimelineStyle.bubbles)
                    Text("Plain").tag(TimelineStyle.plain)
                }
                .pickerStyle(.radioGroup)
            } footer: {
                SettingsFooter(
                    "Plain lists every message on the left with names and avatars, like Telegram's list mode.")
            }
            Section {
                // One stop per step of View ▸ Bigger and Smaller, as Messages' text size slider.
                Slider(
                    value: Binding(
                        get: { Double(TextSize.steps.firstIndex(of: TextSize.next(from: textScale, by: 0)) ?? 1) },
                        set: { TextSize.set(TextSize.steps[Int($0.rounded())]) }),
                    in: 0...Double(TextSize.steps.count - 1), step: 1
                ) {
                    Text("Text size")
                } minimumValueLabel: {
                    Text("A").font(.caption).accessibilityLabel("Smaller")
                } maximumValueLabel: {
                    Text("A").font(.title2).accessibilityLabel("Bigger")
                }
            } footer: {
                SettingsFooter("View ▸ Bigger (⌘+) and Smaller (⌘−) change it too.")
            }
            Section {
                Toggle("Open conversation windows as tabs", isOn: $windowsAsTabs)
            } header: {
                Text("Windows")
            } footer: {
                SettingsFooter(
                    "A conversation opened in a new window joins the conversation window already open as a tab. Window ▸ Merge All Windows joins them either way."
                )
            }
        }
    }
}

/// The colour well for one appearance's bubbles. It holds its own colour: bound straight to the stored hex, the panel's
/// Display P3 colour never matched the sRGB read back, so each answer re-saved it and the panel never settled.
struct BubbleColorPicker: View {
    @Binding var hex: String
    @State private var color: Color
    init(hex: Binding<String>) {
        _hex = hex
        _color = State(initialValue: Color(nsColor: NSColor(hex: hex.wrappedValue) ?? .controlAccentColor))
    }
    var body: some View {
        ColorPicker("Bubble color", selection: $color, supportsOpacity: false)
            .labelsHidden().help("Your bubbles")
            .task(id: color) {  // saved once the colour stops moving, so a drag doesn't redraw every row on every step
                try? await Task.sleep(for: .milliseconds(150))
                guard !Task.isCancelled, let change = Self.change(from: hex, to: color) else { return }
                hex = change
            }
            .onChange(of: hex) {
                if Self.change(from: hex, to: color) != nil {
                    color = Color(nsColor: NSColor(hex: hex) ?? .controlAccentColor)
                }
            }
    }
    /// The hex to save for `picked`, or nil when it rounds to the one already stored.
    static func change(from stored: String, to picked: Color) -> String? {
        guard let hex = NSColor(picked).hex, hex != stored else { return nil }
        return hex
    }
}
