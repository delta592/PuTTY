import AppKit
import Foundation

/// Converts trackpad / mouse-wheel deltas into terminal scroll lines (Phase 9.3).
///
/// Trackpad (precise) deltas are in points and use the cell height as the
/// line unit so momentum scrolling feels continuous. Classic mouse wheels
/// keep a fixed tick height. AppKit already delivers momentum events with
/// non-zero `scrollingDeltaY` while `momentumPhase` is active — callers
/// feed every event through `consumeLines`.
public enum TerminalScrollInput {
    public static let defaultWheelLineHeight: CGFloat = 3

    /// Accumulate `deltaY` and return whole lines to scroll (sign matches
    /// AppKit: positive `deltaY` is content moving down / view scrolling up).
    public static func consumeLines(
        deltaY: CGFloat,
        hasPreciseDeltas: Bool,
        cellHeight: CGFloat,
        wheelLineHeight: CGFloat = defaultWheelLineHeight,
        accumulator: inout CGFloat
    ) -> Int32 {
        let unit: CGFloat
        if hasPreciseDeltas {
            unit = max(cellHeight, 1)
        } else {
            unit = max(wheelLineHeight, 1)
        }
        accumulator += deltaY
        let lines = Int32(accumulator / unit)
        if lines != 0 {
            accumulator -= CGFloat(lines) * unit
        }
        return lines
    }
}
