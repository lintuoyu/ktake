import AppKit
import SwiftUI

enum StudioTheme {
    static let canvas = Color(red: 0.065, green: 0.043, blue: 0.088)
    static let chrome = Color(red: 0.107, green: 0.073, blue: 0.132)
    static let library = Color(red: 0.088, green: 0.059, blue: 0.111)
    static let inspector = Color(red: 0.119, green: 0.085, blue: 0.147)
    static let inset = Color.white.opacity(0.055)
    static let separator = Color(red: 0.86, green: 0.72, blue: 0.92).opacity(0.14)

    static let accent = Color(red: 1, green: 0.65, blue: 0.76)
    static let lyric = Color(red: 1, green: 0.83, blue: 0.72)
    static let amber = Color(red: 1, green: 0.77, blue: 0.42)
    static let live = Color(red: 1, green: 0.43, blue: 0.51)
    static let quick = Animation.easeOut(duration: 0.17)

    private static let purple = Color(red: 0.48, green: 0.27, blue: 0.79)
    static let action = LinearGradient(
        colors: [amber, Color(red: 1, green: 0.57, blue: 0.64), Color(red: 0.77, green: 0.64, blue: 1)],
        startPoint: .topLeading, endPoint: .bottomTrailing
    )
    static let stageLight = RadialGradient(
        colors: [purple.opacity(0.18), purple.opacity(0.05), .clear],
        center: .top, startRadius: 0, endRadius: 570
    )
    static let appIcon = Bundle.main.url(forResource: "AppIcon", withExtension: "icns")
        .flatMap { NSImage(contentsOf: $0) }
}

struct StudioActionStyle: ButtonStyle {
    enum Emphasis { case primary, quiet, recording }
    var emphasis: Emphasis = .quiet
    var cornerRadius: CGFloat = 9

    func makeBody(configuration: Configuration) -> some View {
        Surface(label: configuration.label, pressed: configuration.isPressed,
                emphasis: emphasis, cornerRadius: cornerRadius)
    }

    private struct Surface<Label: View>: View {
        let label: Label
        let pressed: Bool
        let emphasis: Emphasis
        let cornerRadius: CGFloat
        @Environment(\.isEnabled) private var enabled
        @Environment(\.accessibilityReduceMotion) private var reduceMotion
        @State private var hovered = false

        var body: some View {
            let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
            label
                .foregroundStyle(ink)
                .background(fill, in: shape)
                .overlay {
                    shape.strokeBorder(emphasis == .recording ? StudioTheme.live.opacity(0.5) : StudioTheme.separator)
                }
                .overlay {
                    shape.fill(.white.opacity(enabled && (hovered || pressed) ? 0.09 : 0))
                }
                .contentShape(shape)
                .opacity(enabled ? 1 : 0.42)
                .scaleEffect(!reduceMotion && pressed ? 0.97 : 1)
                .onHover { hovered = $0 }
                .animation(reduceMotion ? nil : StudioTheme.quick, value: hovered)
                .animation(reduceMotion ? nil : StudioTheme.quick, value: pressed)
        }

        private var ink: Color {
            switch emphasis {
            case .primary: StudioTheme.canvas
            case .quiet: .white
            case .recording: StudioTheme.live
            }
        }

        private var fill: AnyShapeStyle {
            switch emphasis {
            case .primary: AnyShapeStyle(StudioTheme.action)
            case .quiet: AnyShapeStyle(StudioTheme.inset)
            case .recording: AnyShapeStyle(StudioTheme.live.opacity(0.12))
            }
        }
    }
}

extension View {
    func studioSheet() -> some View {
        presentationBackground(StudioTheme.chrome)
            .tint(StudioTheme.accent)
    }
}
