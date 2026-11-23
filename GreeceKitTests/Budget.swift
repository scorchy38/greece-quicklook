import XCTest
import Darwin

/// Speed budgets for performance tests. A budget only means something when the Mac isn't busy
/// with other work (parallel builds, indexing, another test run). On an idle machine a miss fails
/// as usual; on a busy one it skips the test with the numbers, instead of failing it for the
/// machine's sake.
enum Budget {
    /// The last minute's load average against the cores available.
    static var machineIsBusy: Bool {
        var load = [Double](repeating: 0, count: 3)
        guard getloadavg(&load, 3) == 3 else { return false }
        return load[0] > Double(ProcessInfo.processInfo.activeProcessorCount) * 0.6
    }
}

/// `seconds < budget`, or a skip when it isn't and the machine is busy.
func XCTAssertWithinBudget(_ seconds: Double, _ budget: Double, _ message: String = "",
                           file: StaticString = #filePath, line: UInt = #line) throws {
    if seconds >= budget, Budget.machineIsBusy {
        throw XCTSkip(String(format: "%.3f s against a %.3f s budget while the machine is busy", seconds, budget)
                      + (message.isEmpty ? "" : " (\(message))"))
    }
    XCTAssertLessThan(seconds, budget, message, file: file, line: line)
}
