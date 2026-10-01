import CoreGraphics
import Testing
@testable import Shotsy

@Suite("Swipe gesture rules")
struct SwipeDecisionTests {
    let threshold: CGFloat = 110

    func decide(_ dx: CGFloat, _ dy: CGFloat, predicted: CGSize? = nil) -> SwipeDecision {
        let t = CGSize(width: dx, height: dy)
        return SwipeDecision.classify(translation: t, predicted: predicted ?? t, threshold: threshold)
    }

    @Test func horizontalSwipesKeepAndMark() {
        #expect(decide(120, 0) == .keep)
        #expect(decide(-120, 0) == .mark)
        #expect(decide(120, 60) == .keep, "Downward-ish drags stay horizontal")
        #expect(decide(-130, -100) == .mark, "Mostly sideways wins over a little upward movement")
    }

    @Test func shortDragsCancel() {
        #expect(decide(50, 0) == .cancel)
        #expect(decide(0, -80) == .cancel)
        #expect(decide(0, 0) == .cancel)
    }

    @Test func flicksUseThePredictedEnd() {
        #expect(decide(40, 0, predicted: CGSize(width: 260, height: 0)) == .keep)
        #expect(decide(-40, 0, predicted: CGSize(width: -260, height: 0)) == .mark)
        #expect(decide(5, -40, predicted: CGSize(width: 10, height: -260)) == .album)
    }

    @Test func upwardSwipeFilesIntoAlbum() {
        #expect(decide(0, -120) == .album)
        #expect(decide(80, -130) == .album, "Mostly vertical up")
        #expect(decide(-60, -200) == .album)
    }

    @Test func downwardDragsNeverFile() {
        #expect(decide(0, 300) == .cancel)
        #expect(decide(0, 50, predicted: CGSize(width: 0, height: 600)) == .cancel)
    }

    @Test func diagonalExactlyIsNotUpward() {
        #expect(!SwipeDecision.isUpward(CGSize(width: 120, height: -120)))
        #expect(decide(120, -120) == .keep)
    }

    @Test func cardOffsetDampsVerticalUnlessClearlyUp() {
        // Horizontal and downward drags keep the original damping.
        #expect(SwipeDecision.cardOffset(for: CGSize(width: 100, height: 40)) == CGSize(width: 100, height: 10))
        #expect(SwipeDecision.cardOffset(for: CGSize(width: 100, height: -40)) == CGSize(width: 100, height: -10))
        // Clearly upward follows the finger.
        #expect(SwipeDecision.cardOffset(for: CGSize(width: 10, height: -200)) == CGSize(width: 10, height: -200))
        // In between, it blends instead of jumping.
        let mid = SwipeDecision.cardOffset(for: CGSize(width: 0, height: -20))
        #expect(mid.height < -5 && mid.height > -20)
    }

    @Test func albumStampOnlyForUpward() {
        #expect(SwipeDecision.albumAmount(offset: CGSize(width: 0, height: -200), threshold: threshold) == 1)
        #expect(SwipeDecision.albumAmount(offset: CGSize(width: 0, height: -20), threshold: threshold) == 0)
        #expect(SwipeDecision.albumAmount(offset: CGSize(width: 0, height: 200), threshold: threshold) == 0)
        #expect(SwipeDecision.albumAmount(offset: CGSize(width: 200, height: -100), threshold: threshold) == 0)
    }
}
