import Foundation
import Testing

@testable import Luma

struct DeadlineTests {

    @Test func fastOperationFinishesInTime() async {
        let finished = await Deadline.run(.seconds(5)) {}
        #expect(finished)
    }

    @Test func hungOperationIsAbandonedOnTime() async {
        let clock = ContinuousClock()
        let start = clock.now
        let finished = await Deadline.run(.milliseconds(100)) {
            // Stands in for a call that never returns; keeps running after
            // being abandoned, which is the documented cost.
            try? await Task.sleep(for: .seconds(10))
        }
        #expect(!finished)
        #expect(clock.now - start < .seconds(5), "caller must not be held past the deadline")
    }

    @Test func operationResultIsNotDoubleReported() async {
        // Finish almost exactly at the deadline repeatedly; the once-flag
        // must keep every call to a single, consistent answer (no crash from
        // a double continuation resume).
        for _ in 0..<20 {
            _ = await Deadline.run(.milliseconds(10)) {
                try? await Task.sleep(for: .milliseconds(10))
            }
        }
    }
}
