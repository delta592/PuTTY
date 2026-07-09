import AppKit
import Foundation
import PuttyBridge

/// Off-screen harness exercising the full Swift Core Text paint path (Phase 4.4).
@MainActor
final class TermPerfHarness {
    private var termWin: OpaquePointer?
    private var bitmapContext: NSGraphicsContext?
    private let renderer = TerminalTextRenderer()
    private var isPainting = false

    func setup() -> Bool {
        let handle = putty_bridge_termwin_new()
        guard let handle else { return false }
        termWin = handle
        renderer.attach(termWin: handle)

        var callbacks = PuttyBridgeTermWinCallbacks(
            setup_draw_ctx: Self.setupDrawCtx,
            free_draw_ctx: Self.freeDrawCtx,
            draw_text: Self.drawText,
            draw_cursor: Self.drawCursor,
            draw_trust_sigil: Self.drawTrustSigil,
            request_redraw: Self.requestRedraw,
            char_width: Self.charWidth,
            set_cursor_pos: nil,
            set_raw_mouse_mode: nil,
            set_raw_mouse_mode_pointer: nil,
            clip_write: nil,
            clip_request_paste: nil
        )
        let ctx = Unmanaged.passUnretained(self).toOpaque()
        putty_bridge_termwin_set_callbacks(handle, &callbacks, ctx)

        guard putty_bridge_termwin_init_demo(handle) else { return false }

        let font = NSFont(name: "SFMono-Regular", size: 12)
            ?? NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)
        let probe = "M" as NSString
        let charWidth = probe.size(withAttributes: [.font: font]).width
        let cellHeight = ceil(font.ascender - font.descender + font.leading)
        putty_bridge_termwin_set_font_metrics(
            handle, charWidth, cellHeight, font.ascender, -font.descender
        )
        renderer.refreshMetrics()

        guard putty_bridge_termwin_resize_grid(handle, 80, 120) else { return false }

        let cellW = putty_bridge_termwin_cell_width_pt(handle)
        let cellH = putty_bridge_termwin_cell_height_pt(handle)
        let pixelW = max(1, Int(ceil(cellW * 80)))
        let pixelH = max(1, Int(ceil(cellH * 120)))
        guard let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: pixelW,
            pixelsHigh: pixelH,
            bitsPerSample: 8,
            samplesPerPixel: 4,
            hasAlpha: true,
            isPlanar: false,
            colorSpaceName: .deviceRGB,
            bytesPerRow: 0,
            bitsPerPixel: 0
        ), let ctx = NSGraphicsContext(bitmapImageRep: rep) else {
            return false
        }
        bitmapContext = ctx
        return true
    }

    func runBenchmark(frames: Int32, budgetMs: Double) -> Int32 {
        guard let termWin, let bitmapContext else { return 1 }

        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = bitmapContext
        defer { NSGraphicsContext.restoreGraphicsState() }

        return putty_bridge_termwin_perf_paint_benchmark(termWin, frames, budgetMs)
    }

    func teardown() {
        if let termWin {
            putty_bridge_termwin_free(termWin)
            self.termWin = nil
        }
    }

    // MARK: - C callbacks

    private static let setupDrawCtx: @convention(c) (UnsafeMutableRawPointer?) -> Bool = { ctx in
        guard let ctx else { return false }
        let harness = Unmanaged<TermPerfHarness>.fromOpaque(ctx).takeUnretainedValue()
        return harness.beginDraw()
    }

    private static let freeDrawCtx: @convention(c) (UnsafeMutableRawPointer?) -> Void = { ctx in
        guard let ctx else { return }
        let harness = Unmanaged<TermPerfHarness>.fromOpaque(ctx).takeUnretainedValue()
        harness.endDraw()
    }

    private static let drawText: @convention(c) (
        UnsafeMutableRawPointer?, UnsafePointer<PuttyBridgeTermWinDrawParams>?
    ) -> Void = { ctx, params in
        guard let ctx, let params else { return }
        let request = terminalDrawRequest(from: params.pointee, isCursor: false)
        let harness = Unmanaged<TermPerfHarness>.fromOpaque(ctx).takeUnretainedValue()
        harness.enqueueDraw(request)
    }

    private static let drawCursor: @convention(c) (
        UnsafeMutableRawPointer?, UnsafePointer<PuttyBridgeTermWinDrawParams>?
    ) -> Void = { ctx, params in
        guard let ctx, let params else { return }
        let request = terminalDrawRequest(from: params.pointee, isCursor: true)
        let harness = Unmanaged<TermPerfHarness>.fromOpaque(ctx).takeUnretainedValue()
        harness.enqueueDraw(request)
    }

    private static let drawTrustSigil: @convention(c) (UnsafeMutableRawPointer?, Int32, Int32) -> Void =
        { ctx, x, y in
            guard let ctx else { return }
            let harness = Unmanaged<TermPerfHarness>.fromOpaque(ctx).takeUnretainedValue()
            harness.enqueueTrustSigil(x: x, y: y)
        }

    private static let requestRedraw: @convention(c) (
        UnsafeMutableRawPointer?, PuttyBridgeTermWinRect
    ) -> Void = { _, _ in }

    private static let charWidth: @convention(c) (UnsafeMutableRawPointer?, Int32) -> Int32 = { ctx, uc in
        guard let ctx else { return 1 }
        let harness = Unmanaged<TermPerfHarness>.fromOpaque(ctx).takeUnretainedValue()
        return harness.measureCharWidth(uc)
    }

    private func beginDraw() -> Bool {
        guard NSGraphicsContext.current != nil, !isPainting else { return false }
        renderer.beginPaint()
        isPainting = true
        return true
    }

    private func endDraw() {
        renderer.endPaint()
        isPainting = false
    }

    private func enqueueDraw(_ request: TerminalDrawRequest) {
        renderer.enqueue(request)
    }

    private func enqueueTrustSigil(x: Int32, y: Int32) {
        renderer.enqueueTrustSigil(x: x, y: y)
    }

    private func measureCharWidth(_ codepoint: Int32) -> Int32 {
        renderer.charWidth(for: codepoint)
    }
}

@main
@MainActor
enum PuttyBridgeTermPerfTest {
    static func main() {
        let harness = TermPerfHarness()
        defer { harness.teardown() }

        guard harness.setup() else {
            fputs("PuttyBridgeTermPerfTest: setup failed\n", stderr)
            exit(EXIT_FAILURE)
        }

        let budgetMs = 1000.0 / 60.0
        let frames: Int32 = 120
        let rc = harness.runBenchmark(frames: frames, budgetMs: budgetMs)
        if rc != 0 {
            fputs(
                "PuttyBridgeTermPerfTest: mean frame \(Double(rc)) ms exceeds budget \(budgetMs) ms\n",
                stderr
            )
            exit(EXIT_FAILURE)
        }

        print("PuttyBridgeTermPerfTest: ok (120×80 Core Text, \(frames) frames, budget \(budgetMs) ms)")
        exit(EXIT_SUCCESS)
    }
}
