import Testing
@testable import ReviewBar

struct TicketLinksTests {
    private let acme = TicketLinks.Config(workspace: "acme", teamKeys: ["KM", "EXA", "SEC"])

    @Test func findsListedKeysOnceTitleFirst() {
        let t = TicketLinks.find(in: ["KM-1 fix (exa-12)", "Closes SEC-9 and km-1.\nSee EXA-2"], config: acme)
        #expect(t.map(\.id) == ["KM-1", "EXA-12", "SEC-9", "EXA-2"])
        #expect(t[0].url == "https://linear.app/acme/issue/KM-1")
    }

    @Test func listedKeysIgnoreOtherPrefixesAndEmbeddedMatches() {
        #expect(TicketLinks.find(in: ["ABC-1, XKM-5, KM-5x, UTF-8"], config: acme).isEmpty)
    }

    @Test func withoutKeysAnyCapitalisedKeyMatches() {
        let any = TicketLinks.Config(workspace: "acme", teamKeys: [])
        #expect(TicketLinks.find(in: ["ENG-42 and web-7, X-1"], config: any).map(\.id) == ["ENG-42"])
    }

    @Test func workspaceFromUrlOrName() {
        #expect(TicketLinks.workspace(from: "https://linear.app/acme/team/ENG/active") == "acme")
        #expect(TicketLinks.workspace(from: " linear.app/acme/ ") == "acme")
        #expect(TicketLinks.workspace(from: "acme") == "acme")
        #expect(TicketLinks.workspace(from: "") == nil)
        #expect(TicketLinks.workspace(from: "https://") == nil)
    }

    @Test func teamKeysAreCleaned() {
        #expect(TicketLinks.teamKeys(from: "eng, KM  sec;x-y") == ["ENG", "KM", "SEC"])
    }
}
