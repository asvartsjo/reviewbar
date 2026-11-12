import Testing
@testable import ReviewBar

struct TicketLinksTests {
    @Test func findsKnownPrefixesOnce() {
        let t = TicketLinks.find(in: "KM-70: fix export (see exa-12, KM-70 and SEC-3)")
        #expect(t.map(\.id) == ["KM-70", "EXA-12", "SEC-3"])
        #expect(t[0].url == "https://linear.app/teachiq/issue/KM-70")
    }

    @Test func ignoresOtherPrefixesAndEmbeddedMatches() {
        #expect(TicketLinks.find(in: "ABC-1, XKM-5, KM-5x, UTF-8").isEmpty)
    }
}

extension TicketLinksTests {
    @Test func scansTitleThenDescriptionWithoutRepeats() {
        let t = TicketLinks.find(in: "KM-1 fix", "Closes SEC-9 and km-1.\nSee EXA-2")
        #expect(t.map(\.id) == ["KM-1", "SEC-9", "EXA-2"])
    }
}
