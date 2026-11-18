import AppKit
import SwiftUI

/// Scrolls Home during its local card gesture, which does not use AppKit's drag-and-drop autoscrolling.
@MainActor
final class HomeDragScroll {
    weak var anchor: NSView?
    private var timer: Timer?
    private var windowPoint: CGPoint?
    private var lastPoint: CGPoint?
    private var lastTick: TimeInterval = 0
    private var moved: ((CGPoint) -> Void)?

    func track(_ point: CGPoint, moved: @escaping (CGPoint) -> Void) {
        guard let anchor, anchor.window != nil else { return }
        windowPoint = anchor.convert(point, to: nil)
        lastPoint = point
        self.moved = moved
        guard timer == nil else { return }
        lastTick = ProcessInfo.processInfo.systemUptime
        let timer = Timer(timeInterval: 1.0 / 60, repeats: true) { [weak self] timer in
            MainActor.assumeIsolated {
                guard let self else { timer.invalidate(); return }
                self.tick()
            }
        }
        self.timer = timer
        // Keep ticking while the mouse is held still, including AppKit's event-tracking mode.
        RunLoop.main.add(timer, forMode: .common)
    }

    func stop() {
        timer?.invalidate()
        timer = nil
        windowPoint = nil
        lastPoint = nil
        moved = nil
    }

    private func tick() {
        guard let anchor, anchor.window != nil, let scroll = anchor.enclosingScrollView,
              let document = scroll.documentView, let windowPoint else { return }
        let now = ProcessInfo.processInfo.systemUptime
        let elapsed = min(max(now - lastTick, 0), 0.05)
        lastTick = now
        let clip = scroll.contentView
        let viewport = anchor.convert(clip.bounds, from: clip)
        let point = anchor.convert(windowPoint, from: nil)
        let edge: CGFloat = min(44, viewport.height / 4)
        var speed: CGFloat = 0
        if point.x >= viewport.minX - edge && point.x <= viewport.maxX + edge {
            if point.y < viewport.minY + edge {
                speed = -720 * min(1, (viewport.minY + edge - point.y) / edge)
            } else if point.y > viewport.maxY - edge {
                speed = 720 * min(1, (point.y - viewport.maxY + edge) / edge)
            }
        }
        if speed != 0 {
            var next = clip.bounds
            next.origin.y += speed * elapsed * (document.isFlipped ? 1 : -1)
            next = clip.constrainBoundsRect(next)
            if next.origin != clip.bounds.origin {
                clip.scroll(to: next.origin)
                scroll.reflectScrolledClipView(clip)
            }
        }
        // Scrolling changes grid coordinates even when no new drag event arrives. Keep the lifted card
        // under the stationary pointer and move it through the newly revealed slots.
        let updated = anchor.convert(windowPoint, from: nil)
        if updated != lastPoint {
            lastPoint = updated
            moved?(updated)
        }
    }
}

struct HomeDragScrollAnchor: NSViewRepresentable {
    let scrolling: HomeDragScroll

    final class Anchor: NSView {
        override var isFlipped: Bool { true }
        override func hitTest(_ point: NSPoint) -> NSView? { nil }
    }

    func makeNSView(context: Context) -> Anchor {
        let view = Anchor()
        scrolling.anchor = view
        return view
    }

    func updateNSView(_ view: Anchor, context: Context) { scrolling.anchor = view }
}
