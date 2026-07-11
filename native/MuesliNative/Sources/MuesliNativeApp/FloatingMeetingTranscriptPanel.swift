import AppKit
import Observation
import SwiftUI

enum FloatingMeetingTranscriptPlacement {
    static let panelSize = NSSize(width: 360, height: 320)
    static let gap: CGFloat = 0
    static let screenInset: CGFloat = 8

    static func frame(
        beside indicatorFrame: NSRect,
        panelSize: NSSize = panelSize,
        visibleFrame: NSRect
    ) -> NSRect {
        let availableOnLeft = indicatorFrame.minX - visibleFrame.minX
        let availableOnRight = visibleFrame.maxX - indicatorFrame.maxX
        let prefersLeft = availableOnLeft >= panelSize.width + gap || availableOnLeft >= availableOnRight
        let proposedX = prefersLeft
            ? indicatorFrame.minX - gap - panelSize.width
            : indicatorFrame.maxX + gap
        let minX = visibleFrame.minX + screenInset
        let maxX = max(minX, visibleFrame.maxX - screenInset - panelSize.width)
        let minY = visibleFrame.minY + screenInset
        let maxY = max(minY, visibleFrame.maxY - screenInset - panelSize.height)
        return NSRect(
            x: min(max(proposedX, minX), maxX),
            y: min(max(indicatorFrame.midY - panelSize.height / 2, minY), maxY),
            width: panelSize.width,
            height: panelSize.height
        )
    }
}

enum FloatingMeetingTranscriptContent {
    static func messages(from transcript: String) -> [TranscriptChatMessage] {
        TranscriptChatMessage.messages(from: transcript)
    }

}

@MainActor
@Observable
final class FloatingMeetingTranscriptModel {
    var transcript = ""
    var partialYou = ""
    var partialOthers = ""
    var committedMessages: [TranscriptChatMessage] = []
    var isPaused = false
    var isPresented = false
    var revision = 0

    func update(transcript: String, partialYou: String, partialOthers: String) {
        guard self.transcript != transcript ||
                self.partialYou != partialYou ||
                self.partialOthers != partialOthers else { return }
        if transcript != self.transcript {
            if transcript.hasPrefix(self.transcript) {
                let appended = String(transcript.dropFirst(self.transcript.count))
                committedMessages.append(contentsOf: FloatingMeetingTranscriptContent.messages(from: appended))
            } else {
                committedMessages = FloatingMeetingTranscriptContent.messages(from: transcript)
            }
            self.transcript = transcript
        }
        self.partialYou = partialYou
        self.partialOthers = partialOthers
        revision &+= 1
    }

    func reset() {
        transcript = ""
        partialYou = ""
        partialOthers = ""
        committedMessages = []
        isPaused = false
        isPresented = false
        revision &+= 1
    }
}

@MainActor
final class FloatingMeetingTranscriptPanelController {
    private let model = FloatingMeetingTranscriptModel()
    private let onHoverChanged: (Bool) -> Void
    private let onOpenNotes: () -> Void
    private let onDismiss: () -> Void
    private var hostingView: NSHostingView<FloatingMeetingTranscriptPanelView>?

    init(
        onHoverChanged: @escaping (Bool) -> Void,
        onOpenNotes: @escaping () -> Void,
        onDismiss: @escaping () -> Void
    ) {
        self.onHoverChanged = onHoverChanged
        self.onOpenNotes = onOpenNotes
        self.onDismiss = onDismiss
    }

    var isVisible: Bool {
        hostingView?.superview != nil && hostingView?.isHidden == false
    }

    func update(transcript: String, partialYou: String, partialOthers: String) {
        model.update(
            transcript: transcript,
            partialYou: partialYou,
            partialOthers: partialOthers
        )
    }

    func setPaused(_ paused: Bool) {
        model.isPaused = paused
    }

    func show(in containerView: NSView, frame: NSRect) {
        let hostingView = hostingView ?? makeHostingView()
        if hostingView.superview !== containerView {
            hostingView.removeFromSuperview()
            containerView.addSubview(hostingView)
        }
        hostingView.frame = frame
        hostingView.isHidden = false
        model.isPresented = true
    }

    func hide() {
        model.isPresented = false
        hostingView?.isHidden = true
        hostingView?.removeFromSuperview()
    }

    func reset() {
        hide()
        model.reset()
    }

    func close() {
        model.isPresented = false
        hostingView?.removeFromSuperview()
        hostingView = nil
    }

    func containsMouseLocation() -> Bool {
        guard isVisible, let hostingView, let window = hostingView.window else { return false }
        let locationInWindow = window.convertPoint(fromScreen: NSEvent.mouseLocation)
        return hostingView.frame.contains(locationInWindow)
    }

    private func makeHostingView() -> NSHostingView<FloatingMeetingTranscriptPanelView> {
        let hostingView = NSHostingView(
            rootView: FloatingMeetingTranscriptPanelView(
                model: model,
                onHoverChanged: onHoverChanged,
                onOpenNotes: onOpenNotes,
                onDismiss: onDismiss
            )
        )
        hostingView.wantsLayer = true
        return hostingView
    }
}

private struct FloatingMeetingTranscriptPanelView: View {
    let model: FloatingMeetingTranscriptModel
    let onHoverChanged: (Bool) -> Void
    let onOpenNotes: () -> Void
    let onDismiss: () -> Void
    @State private var didCopy = false

    private var partialYou: String {
        model.partialYou.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var partialOthers: String {
        model.partialOthers.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var messages: [TranscriptChatMessage] {
        model.committedMessages
    }

    private var copyText: String {
        LiveTranscriptCopyContent.text(
            transcript: model.transcript,
            partialYou: model.partialYou,
            partialOthers: model.partialOthers
        )
    }

    var body: some View {
        if model.isPresented {
            VStack(spacing: 0) {
                header
                Divider().background(MuesliTheme.surfaceBorder)
                transcript
            }
            .frame(
                width: FloatingMeetingTranscriptPlacement.panelSize.width,
                height: FloatingMeetingTranscriptPlacement.panelSize.height
            )
            .background(.ultraThinMaterial)
            .background(MuesliTheme.backgroundRaised.opacity(0.94))
            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .strokeBorder(MuesliTheme.surfaceBorder, lineWidth: 1)
            }
            .onHover(perform: onHoverChanged)
        }
    }

    private var header: some View {
        HStack(spacing: MuesliTheme.spacing8) {
            Text("Live transcript")
                .font(MuesliTheme.callout().weight(.semibold))
                .foregroundStyle(MuesliTheme.textPrimary)
            Spacer()
            Circle()
                .fill(model.isPaused ? MuesliTheme.textTertiary : MuesliTheme.success)
                .frame(width: 6, height: 6)
            Text(model.isPaused ? "Paused" : "Live")
                .font(MuesliTheme.caption())
                .foregroundStyle(MuesliTheme.textSecondary)
            Button(action: onDismiss) {
                Image(systemName: "chevron.down")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(MuesliTheme.textSecondary)
                    .frame(width: 24, height: 24)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Hide live transcript")
            Button(action: copyTranscript) {
                Image(systemName: didCopy ? "checkmark" : "doc.on.doc")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(didCopy ? MuesliTheme.success : MuesliTheme.textSecondary)
                    .frame(width: 24, height: 24)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(copyText.isEmpty)
            .help("Copy transcript")
        }
        .padding(.horizontal, MuesliTheme.spacing16)
        .frame(height: 42)
    }

    private var transcript: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 6) {
                if messages.isEmpty && partialYou.isEmpty && partialOthers.isEmpty {
                    Text("Waiting for speech…")
                        .font(MuesliTheme.body())
                        .foregroundStyle(MuesliTheme.textTertiary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.top, MuesliTheme.spacing8)
                } else {
                    ForEach(messages) { message in
                        LiveTranscriptBubble(
                            speaker: message.speaker,
                            timestamp: message.timestamp,
                            lines: [message.text],
                            isUser: message.isUser,
                            isPartial: false,
                            onOpen: onOpenNotes
                        )
                    }
                    if !partialOthers.isEmpty {
                        LiveTranscriptBubble(
                            speaker: "Others",
                            timestamp: nil,
                            lines: [partialOthers],
                            isUser: false,
                            isPartial: true,
                            onOpen: onOpenNotes
                        )
                    }
                    if !partialYou.isEmpty {
                        LiveTranscriptBubble(
                            speaker: "You",
                            timestamp: nil,
                            lines: [partialYou],
                            isUser: true,
                            isPartial: true,
                            onOpen: onOpenNotes
                        )
                    }
                }
            }
            .padding(.horizontal, MuesliTheme.spacing12)
            .padding(.vertical, MuesliTheme.spacing8)
        }
        .defaultScrollAnchor(.bottom)
    }

    private func copyTranscript() {
        guard !copyText.isEmpty else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(copyText, forType: .string)
        didCopy = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) {
            didCopy = false
        }
    }

}
