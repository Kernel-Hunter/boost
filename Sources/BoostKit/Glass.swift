import SwiftUI

// The design layer shared by every screen.
//
// On macOS 26 the navigation and control layer (cards that hold the headline
// figure, pills, floating action bars, icon buttons) uses Liquid Glass. Content
// (rows, charts) stays on quiet fills so glass is never stacked on glass or put
// behind long text. On macOS 14 and 15, and whenever Reduce Transparency is on,
// the same call sites fall back to the materials and hairline borders the app
// has always used. Nothing outside this file asks which OS it is running on,
// apart from the sidebar's selection pill.

// MARK: - Scale

/// One corner radius scale, so a card, a pill and a row never disagree.
enum Radius {
    static let small: CGFloat = 10      // rows, chips, icon buttons
    static let medium: CGFloat = 14     // content cards
    static let large: CGFloat = 20      // header cards, floating panels
}

extension Color {
    /// A deeper step of the brand teal for fills that carry white text. The
    /// regular brand teal is for accents and glyphs; white on it is below 3:1.
    static let brandStrong = Color(red: 0.03, green: 0.54, blue: 0.45)
}

extension Font {
    /// Big numbers: the one display style.
    static let boostDisplay = Font.system(size: 30, weight: .semibold, design: .rounded)
    /// Titles: card names, empty states, the selected app.
    static let boostTitle = Font.system(size: 17, weight: .semibold, design: .rounded)
    /// Mid-size figures: popover totals, the app name.
    static let boostValue = Font.system(size: 22, weight: .semibold, design: .rounded)
}

extension MemStats.Level {
    var color: Color {
        switch self {
        case .easy:     return .green
        case .moderate: return .orange
        case .tight:    return .red
        }
    }

    var statusText: String {
        switch self {
        case .easy:     return "Plenty of headroom"
        case .moderate: return "Getting busy"
        case .tight:    return "Under pressure"
        }
    }
}

// MARK: - Glass surface

private struct BoostGlassModifier: ViewModifier {
    let cornerRadius: CGFloat
    let tint: Color?
    let interactive: Bool
    var elevated = false
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        #if compiler(>=6.2)
        if #available(macOS 26, *), !reduceTransparency {
            content.glassEffect(glass, in: shape)
        } else {
            material(content, shape)
        }
        #else
        material(content, shape)
        #endif
    }

    /// What older systems, and builds without the macOS 26 SDK, get.
    private func material(_ content: Content, _ shape: RoundedRectangle) -> some View {
        content
            .background {
                ZStack {
                    shape.fill(.regularMaterial)
                    if let tint { shape.fill(tint.opacity(0.14)) }
                }
            }
            .overlay { shape.strokeBorder(Color.primary.opacity(0.07), lineWidth: 1) }
            .shadow(color: .black.opacity(elevated ? 0.2 : 0), radius: elevated ? 16 : 0, y: elevated ? 6 : 0)
    }

    #if compiler(>=6.2)
    @available(macOS 26, *)
    private var glass: Glass {
        var g = Glass.regular
        if let tint { g = g.tint(tint) }
        return interactive ? g.interactive() : g
    }
    #endif
}

extension View {
    /// Liquid Glass on macOS 26, a material with a hairline border before it.
    func boostGlass(cornerRadius: CGFloat = Radius.medium, tint: Color? = nil,
                    interactive: Bool = false) -> some View {
        modifier(BoostGlassModifier(cornerRadius: cornerRadius, tint: tint, interactive: interactive))
    }

    /// The same, as a capsule: filter fields, sort controls, status pills.
    func boostGlassCapsule(tint: Color? = nil, interactive: Bool = false) -> some View {
        modifier(BoostGlassModifier(cornerRadius: 1000, tint: tint, interactive: interactive))
    }

    /// The big card at the top of a screen: glass, with the shadow the
    /// material fallback needs to lift off the window.
    func boostHeaderCard() -> some View {
        modifier(BoostGlassModifier(cornerRadius: Radius.large, tint: nil, interactive: false, elevated: true))
            .padding(.horizontal, 18).padding(.top, 16).padding(.bottom, 10)
    }

    /// A quiet content surface for charts and grouped content. Deliberately not
    /// glass: it holds information rather than controls.
    func boostSurface(cornerRadius: CGFloat = Radius.medium) -> some View {
        background(.regularMaterial, in: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .strokeBorder(Color.primary.opacity(0.07), lineWidth: 1)
            }
    }
}

/// Groups glass elements so they blend and animate as one sheet. A plain
/// container where Liquid Glass does not exist.
struct BoostGlassContainer<Content: View>: View {
    var spacing: CGFloat = 8
    @ViewBuilder var content: Content

    var body: some View {
        #if compiler(>=6.2)
        if #available(macOS 26, *) {
            GlassEffectContainer(spacing: spacing) { content }
        } else {
            content
        }
        #else
        content
        #endif
    }
}

// MARK: - Buttons

extension View {
    /// Glass button, or a bordered one on earlier systems.
    @ViewBuilder func boostButton() -> some View {
        #if compiler(>=6.2)
        if #available(macOS 26, *) {
            buttonStyle(.glass)
        } else {
            buttonStyle(.bordered)
        }
        #else
        buttonStyle(.bordered)
        #endif
    }

    /// The one primary action on a screen. Brand teal glass, or a solid
    /// prominent button. Pass `.red` for the destructive one.
    @ViewBuilder func boostProminentButton(tint: Color = .brandStrong) -> some View {
        #if compiler(>=6.2)
        if #available(macOS 26, *) {
            buttonStyle(.glassProminent).tint(tint)
        } else {
            buttonStyle(.borderedProminent).tint(tint)
        }
        #else
        buttonStyle(.borderedProminent).tint(tint)
        #endif
    }

    /// A small glyph button for a row that appears on hover.
    func boostIconButtonLabel() -> some View {
        frame(width: 26, height: 22)
            .boostGlass(cornerRadius: 8, interactive: true)
            .contentShape(Rectangle())
    }
}

/// Text-only secondary action: reads as a link, brightens on hover, dims on press.
struct QuietButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        QuietLabel(configuration: configuration)
    }

    private struct QuietLabel: View {
        let configuration: ButtonStyle.Configuration
        @StateObject private var hover = RowHover()
        @Environment(\.isEnabled) private var enabled

        var body: some View {
            configuration.label
                .foregroundStyle(hover.on && enabled ? Color.primary : Color.secondary)
                .opacity(configuration.isPressed ? 0.55 : 1)
                .padding(.horizontal, 4).padding(.vertical, 3)
                .contentShape(Rectangle())
                .onHover { hover.on = $0 }
        }
    }
}

// MARK: - Motion

private struct MotionModifier<V: Equatable>: ViewModifier {
    let animation: Animation?
    let value: V
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func body(content: Content) -> some View {
        content.animation(reduceMotion ? nil : animation, value: value)
    }
}

extension View {
    /// `.animation(_:value:)` that stays still when Reduce Motion is on.
    func boostAnimation<V: Equatable>(_ animation: Animation? = .spring(response: 0.3, dampingFraction: 1.0),
                                      value: V) -> some View {
        modifier(MotionModifier(animation: animation, value: value))
    }

    /// A symbol effect that only runs while `active` and Reduce Motion is off.
    func boostPulse(active: Bool) -> some View {
        modifier(PulseModifier(active: active))
    }
}

private struct PulseModifier: ViewModifier {
    let active: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func body(content: Content) -> some View {
        content.symbolEffect(.pulse, options: .repeating, isActive: active && !reduceMotion)
    }
}

// MARK: - Backdrop

extension View {
    /// The window's source of light. Glass needs something to refract, and a
    /// flat gray field gives it nothing.
    func boostBackdrop(center: UnitPoint = UnitPoint(x: 0.12, y: 0.1), strength: Double = 0.09,
                       opaque: Bool = true) -> some View {
        background {
            ZStack {
                if opaque { Color(nsColor: .windowBackgroundColor) }
                RadialGradient(colors: [Color.brand.opacity(strength), .clear],
                               center: center, startRadius: 0, endRadius: 460)
                RadialGradient(colors: [Color.blue.opacity(strength * 0.45), .clear],
                               center: UnitPoint(x: 0.95, y: 0.95), startRadius: 0, endRadius: 520)
            }
            .ignoresSafeArea()
        }
    }
}

// MARK: - Rows

private struct RowSurface: ViewModifier {
    let hovered: Bool
    let selected: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: Radius.small, style: .continuous)
        content
            .background(shape.fill(selected ? Color.brand.opacity(0.16)
                                   : Color.primary.opacity(hovered ? 0.06 : 0.03)))
            .overlay(shape.strokeBorder(selected ? Color.brand.opacity(0.45)
                                        : Color.primary.opacity(hovered ? 0.13 : 0.05), lineWidth: 1))
            .animation(reduceMotion ? nil : .easeOut(duration: 0.14), value: hovered)
    }
}

extension View {
    /// The card every list row sits on, with its hover and selected states.
    func boostRow(hovered: Bool, selected: Bool = false) -> some View {
        modifier(RowSurface(hovered: hovered, selected: selected))
    }
}

/// The small rounded label next to a name: Paused, Protected, a project kind.
struct Tag: View {
    let text: String
    let color: Color

    init(_ text: String, _ color: Color) { self.text = text; self.color = color }

    var body: some View {
        Text(text)
            .font(.system(size: 9, weight: .semibold))
            .padding(.horizontal, 6).padding(.vertical, 2)
            .background(color.opacity(0.16), in: Capsule())
            .foregroundStyle(color)
    }
}

// MARK: - Empty state

/// A calm, illustration-like composition instead of a lone gray glyph: a disc
/// with two soft rings, the symbol on it and a small sparkle.
struct EmptyStateView<Actions: View>: View {
    let symbol: String
    let title: String
    var detail: String?
    @ViewBuilder var actions: Actions

    var body: some View {
        VStack(spacing: 10) {
            ZStack {
                Circle().fill(Color.brand.opacity(0.05)).frame(width: 112, height: 112)
                Circle().strokeBorder(Color.brand.opacity(0.14), lineWidth: 1).frame(width: 92, height: 92)
                Circle().fill(Color.brand.opacity(0.13)).frame(width: 72, height: 72)
                Image(systemName: symbol)
                    .font(.system(size: 28, weight: .regular))
                    .foregroundStyle(Color.brand.gradient)
                Image(systemName: "sparkle")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(Color.brand.opacity(0.8))
                    .offset(x: 38, y: -36)
            }
            .padding(.bottom, 6)
            .accessibilityHidden(true)

            Text(title).font(.boostTitle)
            if let detail {
                Text(detail)
                    .font(.callout).foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 360)
            }
            actions
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(.horizontal, 22)
    }
}

extension EmptyStateView where Actions == EmptyView {
    init(symbol: String, title: String, detail: String? = nil) {
        self.init(symbol: symbol, title: title, detail: detail) { EmptyView() }
    }
}

// MARK: - Header card

/// The card at the top of Disk, Projects and Large Files: an icon, the figure
/// the tab exists to show, one line under it and the actions on the right.
struct ReclaimHeader<Actions: View>: View {
    let symbol: String
    let value: String
    let unit: String
    let subtitle: String
    var busy = false
    @ViewBuilder var actions: Actions

    var body: some View {
        HStack(alignment: .center, spacing: 20) {
            ZStack {
                Circle().fill(Color.brand.opacity(0.14))
                Image(systemName: symbol)
                    .font(.system(size: 26))
                    .foregroundStyle(Color.brand.gradient)
                    .boostPulse(active: busy)
            }
            .frame(width: 72, height: 72)
            .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 6) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(value)
                        .font(.boostDisplay)
                        .monospacedDigit()
                        .kerning(-0.6)
                        .contentTransition(.numericText())
                    Text(unit).font(.system(size: 14)).foregroundStyle(.secondary)
                }
                .boostAnimation(.spring(response: 0.4, dampingFraction: 1.0), value: value)
                Text(subtitle)
                    .font(.caption).foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            Spacer(minLength: 0)

            VStack(alignment: .trailing, spacing: 8) { actions }
        }
        .padding(.horizontal, 22).padding(.vertical, 18)
        .boostHeaderCard()
    }
}

// MARK: - Floating bar

/// The bar of actions at the foot of a screen. On macOS 26 its pieces float as
/// separate glass elements over the list; before that it is the full-width
/// material strip the app has always had.
struct FloatingBar<Content: View>: View {
    @ViewBuilder var content: Content

    var body: some View {
        if #available(macOS 26, *) {
            BoostGlassContainer(spacing: 12) {
                HStack(spacing: 10) { content }
            }
            .padding(.horizontal, 18).padding(.top, 22).padding(.bottom, 14)
            .background(alignment: .bottom) {
                // Rows scroll under the floating pieces, so a soft scrim keeps
                // their text from showing through between and behind them.
                LinearGradient(stops: [.init(color: Color(nsColor: .windowBackgroundColor).opacity(0), location: 0),
                                       .init(color: Color(nsColor: .windowBackgroundColor).opacity(0.88), location: 0.5),
                                       .init(color: Color(nsColor: .windowBackgroundColor).opacity(0.95), location: 1)],
                               startPoint: .top, endPoint: .bottom)
                    .allowsHitTesting(false)
            }
        } else {
            HStack(spacing: 10) { content }
                .padding(.horizontal, 22).padding(.vertical, 11)
                .background {
                    // Rows scroll under this strip, so a tint under the
                    // material keeps their text from reading through it.
                    ZStack {
                        Color(nsColor: .windowBackgroundColor).opacity(0.6)
                        Rectangle().fill(.regularMaterial)
                    }
                }
                .overlay(alignment: .top) { Divider().opacity(0.5) }
        }
    }
}

/// A short piece of status text that sits in a floating bar. A glass capsule on
/// macOS 26; bare text on the material strip, which already is the surface.
struct InfoPill<Content: View>: View {
    @ViewBuilder var content: Content

    var body: some View {
        if #available(macOS 26, *) {
            content
                .padding(.horizontal, 14).padding(.vertical, 8)
                .boostGlassCapsule()
        } else {
            content
        }
    }
}

extension View {
    /// Pins a floating bar to the foot of a screen. On macOS 26 the list fades
    /// softly out under it (`safeAreaBar` is the system's version of this); before
    /// that the bar is a plain inset and the rows stop above it.
    @ViewBuilder func boostBottomBar<Bar: View>(@ViewBuilder _ bar: () -> Bar) -> some View {
        #if compiler(>=6.2)
        if #available(macOS 26, *) {
            safeAreaBar(edge: .bottom, spacing: 0) { bar() }
        } else {
            safeAreaInset(edge: .bottom, spacing: 0) { bar() }
        }
        #else
        safeAreaInset(edge: .bottom, spacing: 0) { bar() }
        #endif
    }
}
