import AppKit
import Combine
import SwiftUI

enum Brand {
    static let gradient = LinearGradient(
        colors: [Color(red: 0.36, green: 0.90, blue: 0.78), Color(red: 0.40, green: 0.62, blue: 1.0), Color(red: 0.70, green: 0.48, blue: 1.0)],
        startPoint: .leading,
        endPoint: .trailing)
    static let background = Color(red: 0.07, green: 0.075, blue: 0.10)
    static let card = Color.white.opacity(0.055)
    static let hairline = Color.white.opacity(0.09)
}

/// Bars that follow your voice. The newest sound starts in the middle and
/// ripples outward, with a slight drift so the pill never looks frozen.
struct Waveform: View {
    let levels: [CGFloat]
    var barWidth: CGFloat = 3.5
    var maxHeight: CGFloat = 26

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30.0)) { context in
            let time = context.date.timeIntervalSinceReferenceDate
            let last = levels.count - 1
            HStack(spacing: 3) {
                ForEach(-last...last, id: \.self) { index in
                    let distance = abs(index)
                    let envelope = 1 - CGFloat(distance) / CGFloat(last + 2) * 0.55
                    let drift = CGFloat(sin(time * 5 + Double(index) * 0.8)) * 0.035 + 0.05
                    let height = max(4, (levels[distance] + drift) * envelope * maxHeight)
                    Capsule().frame(width: barWidth, height: min(height, maxHeight))
                }
            }
            .frame(height: maxHeight)
            .animation(.easeOut(duration: 0.09), value: levels)
        }
        .foregroundStyle(Brand.gradient)
    }
}

private struct PulsingDots: View {
    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30.0)) { context in
            let time = context.date.timeIntervalSinceReferenceDate
            HStack(spacing: 5) {
                ForEach(0..<3, id: \.self) { index in
                    let wave = (sin(time * 6 - Double(index) * 0.9) + 1) / 2
                    Circle()
                        .frame(width: 6, height: 6)
                        .scaleEffect(0.7 + wave * 0.5)
                        .opacity(0.45 + wave * 0.55)
                }
            }
        }
        .foregroundStyle(Brand.gradient)
    }
}

struct PillContent: View {
    let phase: AppModel.Phase
    let levels: [CGFloat]

    var body: some View {
        Group {
            switch phase {
            case .hidden:
                EmptyView()
            case .listening:
                Waveform(levels: levels).padding(.horizontal, 6)
            case .handsFree:
                HStack(spacing: 12) {
                    Waveform(levels: levels)
                    Text("Say “send it” or tap").foregroundStyle(.white.opacity(0.75))
                }
            case .transcribing:
                HStack(spacing: 10) {
                    PulsingDots()
                    Text("Writing").foregroundStyle(.white.opacity(0.85))
                }
            case .thinking:
                HStack(spacing: 10) {
                    PulsingDots()
                    Text("Claude is thinking").foregroundStyle(.white.opacity(0.85))
                }
            case .speaking:
                HStack(spacing: 8) {
                    Image(systemName: "speaker.wave.2.fill").foregroundStyle(Brand.gradient)
                    Text("Claude is speaking").foregroundStyle(.white.opacity(0.85))
                    Text("esc to stop").foregroundStyle(.white.opacity(0.5))
                }
            case .done:
                HStack(spacing: 8) {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(Color(red: 0.36, green: 0.90, blue: 0.78))
                    Text("Done").foregroundStyle(.white.opacity(0.9))
                }
            case .message(let text):
                HStack(spacing: 8) {
                    Image(systemName: "exclamationmark.circle.fill")
                        .foregroundStyle(Color(red: 1.0, green: 0.74, blue: 0.36))
                    Text(text).foregroundStyle(.white.opacity(0.92)).lineLimit(1)
                }
            }
        }
        .font(.system(size: 13, weight: .medium, design: .rounded))
        .padding(.horizontal, 18)
        .frame(height: 46)
        .background(
            Capsule()
                .fill(Color(red: 0.06, green: 0.065, blue: 0.09).opacity(0.96))
                .overlay(Capsule().strokeBorder(Color.white.opacity(0.13), lineWidth: 1))
        )
        .shadow(color: .black.opacity(0.4), radius: 14, y: 6)
    }
}

private struct OverlayView: View {
    @ObservedObject var model: AppModel

    var body: some View {
        ZStack(alignment: .bottom) {
            Color.clear
            if model.phase != .hidden {
                PillContent(phase: model.phase, levels: model.levels)
                    .padding(.bottom, 22)
                    .transition(.scale(scale: 0.7, anchor: .bottom).combined(with: .opacity))
            }
        }
        .animation(.spring(response: 0.32, dampingFraction: 0.72), value: model.phase)
    }
}

/// A click-through panel near the bottom of the screen. It never takes focus,
/// so your text cursor stays where it is while you talk.
final class OverlayController {
    private let panel: NSPanel
    private var phaseWatcher: AnyCancellable?
    private var pendingHide: DispatchWorkItem?

    init(model: AppModel) {
        panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 420, height: 110),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.level = .statusBar
        panel.ignoresMouseEvents = true
        panel.hidesOnDeactivate = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        panel.contentView = NSHostingView(rootView: OverlayView(model: model))

        phaseWatcher = model.$phase.removeDuplicates().sink { [weak self] phase in
            self?.update(for: phase)
        }
    }

    private func update(for phase: AppModel.Phase) {
        pendingHide?.cancel()
        if phase == .hidden {
            // Stay up long enough for the exit animation to finish.
            let hide = DispatchWorkItem { [weak self] in self?.panel.orderOut(nil) }
            pendingHide = hide
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.4, execute: hide)
            return
        }
        if let screen = NSScreen.main {
            let area = screen.visibleFrame
            panel.setFrameOrigin(NSPoint(x: area.midX - panel.frame.width / 2, y: area.minY + 8))
        }
        panel.orderFrontRegardless()
    }
}
