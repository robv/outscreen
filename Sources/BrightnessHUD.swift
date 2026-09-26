import AppKit

/// A display-local brightness indicator that never takes keyboard focus.
@MainActor
final class BrightnessHUD {
    private let panel: BrightnessHUDPanel
    private let displayLabel = NSTextField(labelWithString: "")
    private let percentageLabel = NSTextField(labelWithString: "")
    private let track = BrightnessHUDTrack(frame: NSRect(x: 59, y: 29, width: 180, height: 6))
    private var dismissal: DispatchWorkItem?

    init() {
        panel = BrightnessHUDPanel(
            contentRect: NSRect(x: 0, y: 0, width: 260, height: 90),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.ignoresMouseEvents = true
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.level = .statusBar
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
        panel.animationBehavior = .none
        panel.setAccessibilityLabel("Display brightness")

        let backdrop = NSVisualEffectView(frame: NSRect(x: 0, y: 0, width: 260, height: 90))
        backdrop.material = .hudWindow
        backdrop.blendingMode = .behindWindow
        backdrop.state = .active
        backdrop.appearance = NSAppearance(named: .vibrantDark)
        backdrop.wantsLayer = true
        backdrop.layer?.cornerRadius = 19
        backdrop.layer?.masksToBounds = true
        panel.contentView = backdrop

        let icon = NSImageView(frame: NSRect(x: 18, y: 32, width: 28, height: 28))
        icon.image = NSImage(systemSymbolName: "sun.max.fill", accessibilityDescription: "Brightness")
        icon.contentTintColor = .white
        icon.imageScaling = .scaleProportionallyUpOrDown
        backdrop.addSubview(icon)

        displayLabel.frame = NSRect(x: 57, y: 47, width: 144, height: 19)
        displayLabel.font = .systemFont(ofSize: 12, weight: .medium)
        displayLabel.textColor = .white
        displayLabel.lineBreakMode = .byTruncatingTail
        backdrop.addSubview(displayLabel)

        percentageLabel.frame = NSRect(x: 201, y: 47, width: 40, height: 19)
        percentageLabel.font = .monospacedDigitSystemFont(ofSize: 12, weight: .regular)
        percentageLabel.textColor = NSColor.white.withAlphaComponent(0.8)
        percentageLabel.alignment = .right
        backdrop.addSubview(percentageLabel)
        backdrop.addSubview(track)
    }

    func show(value: Float, displayID: UInt32) {
        guard value.isFinite,
              let screen = NSScreen.screens.first(where: {
                  ($0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value == displayID
              }) else { return }
        let brightness = min(max(value, 0), 1)
        displayLabel.stringValue = screen.localizedName
        percentageLabel.stringValue = "\(Int((brightness * 100).rounded()))%"
        track.value = CGFloat(brightness)
        panel.setAccessibilityValue("\(screen.localizedName), \(percentageLabel.stringValue)")

        let area = screen.visibleFrame
        panel.setFrameOrigin(NSPoint(x: area.midX - panel.frame.width / 2, y: area.minY + 54))
        panel.orderFrontRegardless()

        dismissal?.cancel()
        let hide = DispatchWorkItem { [weak panel] in panel?.orderOut(nil) }
        dismissal = hide
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2, execute: hide)
    }

    deinit {
        dismissal?.cancel()
    }
}

private final class BrightnessHUDPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

private final class BrightnessHUDTrack: NSView {
    var value: CGFloat = 0 {
        didSet { needsDisplay = true }
    }

    override func draw(_ dirtyRect: NSRect) {
        NSColor.white.withAlphaComponent(0.2).setFill()
        NSBezierPath(roundedRect: bounds, xRadius: 3, yRadius: 3).fill()
        guard value > 0 else { return }
        NSGraphicsContext.saveGraphicsState()
        NSBezierPath(roundedRect: bounds, xRadius: 3, yRadius: 3).addClip()
        NSColor.white.setFill()
        NSRect(x: bounds.minX, y: bounds.minY, width: bounds.width * value, height: bounds.height).fill()
        NSGraphicsContext.restoreGraphicsState()
    }
}
