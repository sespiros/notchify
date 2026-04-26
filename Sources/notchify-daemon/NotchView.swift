import SwiftUI

struct NotchView: View {
    let message: Message
    var notchSize: CGSize
    var onClick: () -> Void = {}
    var onDismiss: () -> Void

    @State private var slidIn = false
    @State private var widthExpanded = false
    @State private var heightExpanded = false
    @State private var textVisible = false
    @State private var iconVisible = false
    @State private var dismissTask: Task<Void, Never>?

    static let leftExtra: CGFloat = 31       // shelf width past notch's left edge in phase 1
    static let extraHeight: CGFloat = 44     // phase-2 height (a bit more than 2x notch for breathing room)

    var body: some View {
        let frameWidth = notchSize.width + (widthExpanded ? Self.leftExtra : 0)
        let frameHeight = notchSize.height + (heightExpanded ? Self.extraHeight : 0)
        let panelWidth = notchSize.width + Self.leftExtra
        let panelHeight = notchSize.height + Self.extraHeight

        ZStack(alignment: .topTrailing) {
            UnevenRoundedRectangle(
                topLeadingRadius: 0,
                bottomLeadingRadius: 9,
                bottomTrailingRadius: 9,
                topTrailingRadius: 0
            )
            .fill(Color.black)
            .frame(width: frameWidth, height: frameHeight)
            .contentShape(Rectangle())
            .onTapGesture {
                onClick()
                dismiss()
            }
            .onHover { hovering in
                if hovering {
                    dismissTask?.cancel()
                } else {
                    scheduleDismiss(in: message.timeout ?? 5.0)
                }
            }

            content
                .frame(width: frameWidth, height: frameHeight, alignment: .topLeading)
        }
        .frame(width: panelWidth, height: panelHeight, alignment: .topTrailing)
        .offset(y: slidIn ? 0 : -(notchSize.height + Self.extraHeight + 4))
        .onAppear { schedule() }
    }

    private var content: some View {
        VStack(spacing: 0) {
            HStack(spacing: 0) {
                if let symbol = message.symbol {
                    Image(systemName: symbol)
                        .resizable()
                        .scaledToFit()
                        .foregroundColor(Self.color(named: message.color) ?? .white)
                        .frame(width: 14, height: 14)
                        .opacity(iconVisible ? 1 : 0)
                } else if let iconPath = message.icon, let img = NSImage(contentsOfFile: iconPath) {
                    Image(nsImage: img)
                        .resizable()
                        .scaledToFit()
                        .frame(width: 18, height: 18)
                        .opacity(iconVisible ? 1 : 0)
                } else {
                    // Default fallback icon when caller doesn't supply one.
                    Image(systemName: "bell.fill")
                        .resizable()
                        .scaledToFit()
                        .foregroundColor(.white)
                        .frame(width: 14, height: 14)
                        .opacity(iconVisible ? 1 : 0)
                }
                Spacer(minLength: 0)
            }
            .padding(.leading, 8)
            .frame(height: notchSize.height)

            VStack(alignment: .leading, spacing: 1) {
                Text(message.title)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(.white)
                    .lineLimit(1)
                Text(message.text)
                    .font(.system(size: 11))
                    .foregroundColor(.white.opacity(0.7))
                    .lineLimit(2)
            }
            .padding(.horizontal, 10)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
            .opacity(textVisible ? 1 : 0)
        }
    }

    private func schedule() {
        // Snappy slide-in then snappy left expand, tiny pause, then a
        // more pronounced drop-down for text. easeOut is cheaper than
        // spring and visually nearly identical at these durations.
        withAnimation(.easeOut(duration: 0.22)) { slidIn = true }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
            withAnimation(.easeOut(duration: 0.18)) { widthExpanded = true }
            withAnimation(.easeIn(duration: 0.12).delay(0.05)) { iconVisible = true }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.7) {
            withAnimation(.easeOut(duration: 0.32)) { heightExpanded = true }
            withAnimation(.easeIn(duration: 0.2).delay(0.2)) { textVisible = true }
        }
        scheduleDismiss(in: message.timeout ?? 5.0)
    }

    private func scheduleDismiss(in seconds: TimeInterval) {
        dismissTask?.cancel()
        dismissTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
            if !Task.isCancelled { dismiss() }
        }
    }

    static func color(named name: String?) -> Color? {
        switch name?.lowercased() {
        case "orange": return .orange
        case "red": return .red
        case "yellow": return .yellow
        case "green": return .green
        case "blue": return .blue
        case "purple": return .purple
        case "pink": return .pink
        case "white": return .white
        case "gray", "grey": return .gray
        default: return nil
        }
    }

    private func dismiss() {
        dismissTask?.cancel()
        // Continuous fluid reverse. Each step staggered slightly so the
        // motion reads as one smooth retraction.
        withAnimation(.easeOut(duration: 0.16)) { textVisible = false }
        withAnimation(.easeInOut(duration: 0.28).delay(0.05)) { heightExpanded = false }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.32) {
            withAnimation(.easeOut(duration: 0.13)) { iconVisible = false }
            withAnimation(.easeInOut(duration: 0.25).delay(0.05)) { widthExpanded = false }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.62) {
            withAnimation(.easeIn(duration: 0.24)) { slidIn = false }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.26) { onDismiss() }
        }
    }
}
