import AppKit
import LandfallCore
import SwiftUI

/// What a toast shows that changes while it's up: the countdown, the status line, whether its buttons still work.
final class ToastState: ObservableObject {
    @Published var model: ToastModel
    /// 1 when the countdown starts, 0 when it runs out.
    @Published var progress: Double = 1
    @Published var status: String = ""
    @Published var statusIsError = false
    @Published var enabled = true

    init(model: ToastModel) { self.model = model }
}

/// One toast. Laid out like Kronist's: a colored bar down the left, the title with ✕ on its line,
/// details with their icons in one column, the primary action filled, the deferral (Keep) on the
/// right, and the countdown draining along the bottom in the bar's color.
struct ToastCard: View {
    static let width: CGFloat = 360

    @ObservedObject var state: ToastState
    /// False for snapshots: a solid background, since materials don't render offscreen.
    var live = true
    var onAction: (FileAction) -> Void = { _ in }
    var onDismiss: () -> Void = {}
    var onHover: (Bool) -> Void = { _ in }

    private var m: ToastModel { state.model }

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            RoundedRectangle(cornerRadius: 2)
                .fill(tint)
                .frame(width: 4)

            VStack(alignment: .leading, spacing: 8) {
                header
                details
                actions
            }
        }
        .padding(14)
        .frame(width: Self.width, alignment: .leading)
        .fixedSize(horizontal: false, vertical: true)
        .background(background)
        .overlay(alignment: .bottom) { countdownBar }
        .clipShape(RoundedRectangle(cornerRadius: 14))
        .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(.separator))
        .onHover(perform: onHover)
        .accessibilityElement(children: .contain)
    }

    @ViewBuilder private var background: some View {
        if live && !NSWorkspace.shared.accessibilityDisplayShouldReduceTransparency {
            RoundedRectangle(cornerRadius: 14).fill(.regularMaterial)
        } else {
            RoundedRectangle(cornerRadius: 14).fill(Color(nsColor: .windowBackgroundColor))
        }
    }

    /// Drains from right to left as the time runs out, and stands still while paused.
    private var countdownBar: some View {
        Rectangle()
            .fill(tint)
            .frame(height: 3)
            .scaleEffect(x: max(0, min(1, state.progress)), y: 1, anchor: .leading)
            .animation(.linear(duration: 0.1), value: state.progress)
            .accessibilityHidden(true)
    }

    // MARK: Header

    private var header: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(alignment: .firstTextBaseline) {
                Text(m.name)
                    .font(.headline)
                    .lineLimit(2)
                    .truncationMode(.middle)
                Spacer(minLength: 8)
                Button(action: onDismiss) {
                    Image(systemName: "xmark")
                        .font(.caption.weight(.semibold))
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .help("Dismiss")
                .accessibilityLabel("Dismiss")
            }
            Text(subtitle)
                .font(.subheadline)
                .foregroundStyle(state.statusIsError ? Color(nsColor: .systemRed) : .secondary)
                .lineLimit(2)
                .monospacedDigit()
        }
    }

    /// "Video · 652.8 MB · files in 12s": what it is, then what's about to happen.
    private var subtitle: String {
        state.status.isEmpty ? m.subtitle : state.statusIsError ? state.status : "\(m.subtitle) · \(state.status)"
    }

    // MARK: Details

    private var details: some View {
        VStack(alignment: .leading, spacing: 4) {
            if showsTrust {
                Label {
                    Text(m.trust.summary).foregroundStyle(trustTextColor).lineLimit(2)
                } icon: {
                    Image(systemName: m.trust.level == .trusted ? "checkmark.seal.fill" : "exclamationmark.triangle.fill")
                        .foregroundStyle(m.trust.level == .trusted ? .secondary : trustTextColor)
                }
            } else if let host = m.trust.originHost {
                Label(host, systemImage: "arrow.down.circle")
            }
            if let dest = m.destinationLabel {
                Label {
                    Text(dest).fontWeight(.medium).lineLimit(2).truncationMode(.middle)
                } icon: {
                    Image(systemName: m.isReceipt ? "checkmark.circle.fill" : isSmart ? "sparkles" : "arrow.turn.down.right")
                        .foregroundStyle(m.isReceipt ? Color.green : isSmart ? Color.purple : Color.secondary)
                }
                .help(m.suggestion ?? "")
            }
            if let why = m.suggestion, m.destinationLabel == nil || (isSmart && !m.isReceipt) {
                Text(why)
                    .foregroundStyle(.secondary)
                    .lineLimit(3)
                    .padding(.top, 2)
            }
        }
        .font(.callout)
        .labelStyle(AlignedIconLabelStyle())
    }

    /// Trust only when it says something: caution, danger, or a signature.
    private var showsTrust: Bool { m.trust.level != .trusted || m.trust.signer != nil }
    private var isSmart: Bool { m.decision?.rule == "ai" }

    private var trustTextColor: Color {
        switch m.trust.level {
        case .trusted: return .secondary
        case .caution: return Color(nsColor: .systemOrange)
        case .danger: return Color(nsColor: .systemRed)
        }
    }

    /// The card's color: what kind of moment this is, else which folder it landed in.
    var tint: Color {
        if m.isReceipt { return Color(nsColor: .systemGreen) }
        switch m.trust.level {
        case .danger: return Color(nsColor: .systemRed)
        case .caution: return Color(nsColor: .systemOrange)
        case .trusted: break
        }
        if isSmart { return Color(nsColor: .systemPurple) }
        switch m.root {
        case "downloads": return Color(nsColor: .systemBlue)
        case "desktop": return Color(nsColor: .systemTeal)
        case "documents": return Color(nsColor: .systemIndigo)
        default: return Color(nsColor: .controlAccentColor)
        }
    }

    // MARK: Actions

    /// Primary filled · ⌄ for the rest · one plain button … Keep on the right, like Kronist's Snooze.
    private var actions: some View {
        let all = m.actions
        let primary = all.first
        let trailing = all.dropFirst().first { $0.kind == .keep }
        let rest = all.dropFirst().filter { $0 != trailing }
        let middle = rest.first
        let more = Array(rest.dropFirst())
        return HStack(spacing: 8) {
            if let primary {
                Button { onAction(primary) } label: { Text(primary.title).lineLimit(1).fixedSize() }
                    .buttonStyle(AccentButtonStyle(fill: primary.confirm == nil ? Color(nsColor: .controlAccentColor) : .orange))
                if !more.isEmpty { moreMenu(more) }
            }
            if let middle { plainButton(middle) }
            Spacer()
            if let trailing { plainButton(trailing) }
        }
        .controlSize(.regular)
        .padding(.top, 4)
        .disabled(!state.enabled)
    }

    private func plainButton(_ a: FileAction) -> some View {
        Button { onAction(a) } label: { Text(a.title).lineLimit(1) }
            .fixedSize()
            .foregroundStyle(a.confirm == nil ? Color.primary : .orange)
    }

    private func moreMenu(_ items: [FileAction]) -> some View {
        Menu {
            ForEach(Array(items.enumerated()), id: \.offset) { _, a in
                Button { onAction(a) } label: {
                    if let symbol = Toast.symbol(for: a.kind) { Label(a.title, systemImage: symbol) } else { Text(a.title) }
                }
            }
        } label: {
            Image(systemName: "chevron.down")
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("More actions")
        .accessibilityLabel("More actions")
    }
}

/// Gives every icon the same column, so the text of each line starts at the same place
/// whatever the symbol's own width.
struct AlignedIconLabelStyle: LabelStyle {
    static let iconWidth: CGFloat = 20

    func makeBody(configuration: Configuration) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            configuration.icon
                .foregroundStyle(.secondary)
                .frame(width: Self.iconWidth, alignment: .center)
            configuration.title
        }
    }
}

/// A filled button that keeps its color in a window without focus. The system's prominent
/// style turns grey there, and a toast never has focus.
struct AccentButtonStyle: ButtonStyle {
    var fill: Color = Color(nsColor: .controlAccentColor)
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .fontWeight(.medium)
            .foregroundStyle(.white)
            .padding(.horizontal, 12)
            .padding(.vertical, 3)
            .background(fill.opacity(!isEnabled ? 0.45 : configuration.isPressed ? 0.75 : 1),
                        in: RoundedRectangle(cornerRadius: 6))
    }
}

/// Toasts never become active, so their buttons must act on the first click.
final class FirstClickHostingView<Content: View>: NSHostingView<Content> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}
