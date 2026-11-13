import AppKit
import Testing
@testable import CodexTokenBar

struct StatusItemTooltipTests {
    @Test func passingOverTheButtonDoesNotShowALateTooltip() {
        var hover = TooltipHoverSession()
        hover.enter(at: 10, isInside: true)
        let duringPass = hover.update(at: 10.2, isInside: true)
        let afterLeaving = hover.update(at: 10.3, isInside: false)
        #expect(!duringPass)
        #expect(!afterLeaving)
        #expect(!hover.isTracking)
        let afterDelay = hover.update(at: 11, isInside: false)
        #expect(!afterDelay)
    }

    @Test func delayedEnterOutsideTheButtonCannotArmTheTooltip() {
        var hover = TooltipHoverSession()
        hover.enter(at: 10, isInside: false)
        #expect(!hover.isTracking)
        let afterDelay = hover.update(at: 11, isInside: true)
        #expect(!afterDelay)
    }

    @Test func hoveringShowsOnlyAfterTheDelayAndClosesWithoutAnExitEvent() {
        var hover = TooltipHoverSession()
        hover.enter(at: 10, isInside: true)
        let beforeDelay = hover.update(at: 10.6, isInside: true)
        let afterDelay = hover.update(at: 10.8, isInside: true)
        let afterLeaving = hover.update(at: 11, isInside: false)
        #expect(!beforeDelay)
        #expect(afterDelay)
        #expect(!afterLeaving)
        #expect(!hover.isTracking)
        // A refresh or timer callback is insufficient; a new enter is required.
        let withoutEnter = hover.update(at: 12, isInside: true)
        #expect(!withoutEnter)
    }

    @Test func clickOrFocusLossCancelsPendingAndVisibleTooltipsUntilThePointerLeaves() {
        for dismissalTime in [10.2, 11.0] {
            var hover = TooltipHoverSession()
            hover.enter(at: 10, isInside: true)
            _ = hover.update(at: dismissalTime, isInside: true)
            hover.dismiss()
            let afterDismissal = hover.update(at: 12, isInside: true)
            #expect(!afterDismissal)
            // Duplicate enter events must not undo a click, menu open, or focus change.
            hover.enter(at: 12, isInside: true)
            let afterDuplicateEnter = hover.update(at: 13, isInside: true)
            let afterLeaving = hover.update(at: 14, isInside: false)
            #expect(!afterDuplicateEnter)
            #expect(!afterLeaving)
            hover.enter(at: 15, isInside: true)
            let beforeNewDelay = hover.update(at: 15.2, isInside: true)
            let afterNewDelay = hover.update(at: 16, isInside: true)
            #expect(!beforeNewDelay)
            #expect(afterNewDelay)
        }
    }

    @Test func duplicateTrackingEventsDoNotRestartTheHoverDelay() {
        var hover = TooltipHoverSession()
        hover.enter(at: 10, isInside: true)
        hover.enter(at: 10.5, isInside: true)
        let afterOriginalDelay = hover.update(at: 10.8, isInside: true)
        #expect(afterOriginalDelay)
        // An out-of-order exit callback checks the actual position, which is still inside.
        let afterLateExit = hover.update(at: 11, isInside: true)
        #expect(afterLateExit)
    }

    @Test func tooltipIsPlacedBelowTheButtonInScreenCoordinates() {
        let anchor = NSRect(x: 1_000, y: 1_050, width: 160, height: 30)
        let frame = TooltipPlacement.frame(size: NSSize(width: 460, height: 200), anchor: anchor,
                                           visibleFrame: NSRect(x: 0, y: 0, width: 1_920, height: 1_050))
        #expect(frame.midX == anchor.midX)
        #expect(frame.maxY == anchor.minY - 8)
    }

    @Test func tooltipStaysOnTheButtonsMonitorAtBothHorizontalEdges() {
        // Include monitors to the left of and above the primary display.
        for screen in [NSRect(x: 0, y: 0, width: 1_920, height: 1_050),
                       NSRect(x: -1_920, y: -200, width: 1_920, height: 1_050),
                       NSRect(x: 200, y: 1_080, width: 1_280, height: 770)] {
            for x in [screen.minX, screen.maxX - 100] {
                let anchor = NSRect(x: x, y: screen.maxY, width: 100, height: 30)
                let frame = TooltipPlacement.frame(size: NSSize(width: 460, height: 200),
                                                   anchor: anchor, visibleFrame: screen)
                #expect(screen.insetBy(dx: 8, dy: 8).contains(frame))
                #expect(frame.maxY < anchor.minY)
            }
        }
    }

    @Test func longWarningsFitWithinTheVisibleScreen() {
        let screen = NSRect(x: -1_280, y: 0, width: 1_280, height: 770)
        let frame = TooltipPlacement.frame(size: NSSize(width: 2_000, height: 2_000),
                                           anchor: NSRect(x: -200, y: 770, width: 100, height: 30),
                                           visibleFrame: screen)
        #expect(frame == screen.insetBy(dx: 8, dy: 8))
    }
}
