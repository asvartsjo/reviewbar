import Foundation
import Testing
@testable import ReviewBar

/// `--demo` is only useful if it keeps covering every state, so this guards the story.
@MainActor
struct DemoDataTests {
    private func list(step: Int) -> [ReviewingPR] {
        Backend.merge(DemoData.reviewing(step: step), requested: DemoData.requests(step: step))
    }

    @Test func firstStepHasEveryTurn() {
        let turns = list(step: 1).map(\.turn)
        let all: [ReviewingPR.Turn] = [.yours(.requested), .yours(.reRequested), .yours(.newCommits),
                                       .yours(.reply), .authors, .done]
        for t in all { #expect(turns.contains(t), "no demo PR for \(t)") }
    }

    @Test func secondStepNotifies() {
        let before = Dictionary(list(step: 1).map { ($0.pr.url, $0) }, uniquingKeysWith: { a, _ in a })
        let alerts = AlertDiff.reviewing(list(step: 2), before: before)
        let kinds = alerts.map { a -> String in
            switch a {
            case .pushed(let r): "pushed \(r.pr.number)"
            case .allResolved(let r): "resolved \(r.pr.number)"
            case .verdict(let r, let v): "\(v.login) \(v.state) \(r.pr.number)"
            default: "other"
            }
        }
        #expect(Set(kinds) == ["pushed 140", "resolved 160", "omar APPROVED 152"])
        let fresh = AlertDiff.newRequests(DemoData.requests(step: 2), seen: Set(DemoData.requests(step: 1).map(\.url)))
        #expect(fresh.map(\.number) == [180])
    }

    /// The detail's threads match the counts on the row, at every step.
    @Test func detailMatchesRow() {
        for step in 1...DemoData.lastStep {
            for r in DemoData.reviewing(step: step) {
                let threads = DemoData.detail(for: r, step: step).myThreads
                #expect(threads.count == r.myThreads, "#\(r.pr.number) threads")
                #expect(threads.filter { $0.state == .resolved }.count == r.resolved, "#\(r.pr.number) resolved")
                #expect(threads.filter(\.isOutdated).count == r.outdated, "#\(r.pr.number) outdated")
                let replied = threads.filter { if case .replied = $0.state { true } else { false } }.count
                #expect(replied == r.waiting, "#\(r.pr.number) waiting")
            }
        }
    }
}
