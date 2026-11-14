import AppKit
import SwiftUI

public struct SelectionGestureModifiers: Equatable, Sendable {
    public let command: Bool
    public let shift: Bool

    public init(command: Bool, shift: Bool) {
        self.command = command
        self.shift = shift
    }

    public var eventModifierFlags: NSEvent.ModifierFlags {
        var flags: NSEvent.ModifierFlags = []
        if command {
            flags.insert(.command)
        }
        if shift {
            flags.insert(.shift)
        }
        return flags
    }
}

public enum GridCardClickDisposition: Equatable, Sendable {
    case select(SelectionGestureModifiers)
    case selectAndOpenSingle
    case ignore
}

public enum GridCardClickAction {
    public static func resolve(
        clickCount: Int,
        isControlModified: Bool,
        isCommandModified: Bool,
        isShiftModified: Bool
    ) -> GridCardClickDisposition {
        if isControlModified {
            return .ignore
        }
        if clickCount >= 2 && !isCommandModified && !isShiftModified {
            return .selectAndOpenSingle
        }
        return .select(
            SelectionGestureModifiers(
                command: isCommandModified,
                shift: isShiftModified
            )
        )
    }
}

struct InstantClickOverlay: NSViewRepresentable {
    let onAction: @MainActor (GridCardClickDisposition) -> Void

    func makeNSView(context: Context) -> InstantClickNSView {
        let view = InstantClickNSView()
        view.onAction = onAction
        return view
    }

    func updateNSView(_ nsView: InstantClickNSView, context: Context) {
        nsView.onAction = onAction
    }
}

final class InstantClickNSView: NSView {
    var onAction: (@MainActor (GridCardClickDisposition) -> Void)?

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool {
        true
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        let localPoint = convert(point, from: superview)
        guard bounds.contains(localPoint),
              let event = NSApp.currentEvent else {
            return nil
        }
        switch event.type {
        case .leftMouseDown, .leftMouseUp, .leftMouseDragged:
            return event.modifierFlags.contains(.control) ? nil : self
        default:
            return nil
        }
    }

    override func mouseDown(with event: NSEvent) {
        let flags = event.modifierFlags
        let disposition = GridCardClickAction.resolve(
            clickCount: event.clickCount,
            isControlModified: flags.contains(.control),
            isCommandModified: flags.contains(.command),
            isShiftModified: flags.contains(.shift)
        )
        guard disposition != .ignore else {
            super.mouseDown(with: event)
            return
        }
        onAction?(disposition)
    }

    override func scrollWheel(with event: NSEvent) {
        nextResponder?.scrollWheel(with: event)
    }
}
