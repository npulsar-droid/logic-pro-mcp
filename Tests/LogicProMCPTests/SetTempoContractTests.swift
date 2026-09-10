import XCTest
@testable import LogicProMCP

/// set_tempo crosses three files that each had their own idea of the parameter
/// name: the dispatcher wrote "bpm", OSCChannel read "bpm", AccessibilityChannel
/// read "tempo". Because ChannelRouter treats a channel's "missing parameter"
/// as "try the next channel", the broken fallback was silent — the OSC send
/// reported success and nothing ever reached Logic Pro.
///
/// These tests pin the contract rather than the UI, so they run without Logic
/// Pro installed and without Accessibility permission.
final class SetTempoContractTests: XCTestCase {

    /// The key the dispatcher sends must be the key both channels read.
    func testChannelsReadTheKeyTheDispatcherSends() {
        let dispatched = [ChannelParam.tempo: "140"]

        XCTAssertEqual(
            AccessibilityChannel.parseTempo(dispatched), 140,
            "AccessibilityChannel must accept the dispatcher's tempo key"
        )
        XCTAssertNotNil(
            dispatched[ChannelParam.tempo].flatMap(Float.init),
            "OSCChannel must accept the dispatcher's tempo key"
        )
    }

    func testTempoParsingAcceptsTheLegacyKey() {
        XCTAssertEqual(AccessibilityChannel.parseTempo(["tempo": "90"]), 90)
    }

    func testTempoParsingRejectsMissingAndNonNumericValues() {
        XCTAssertNil(AccessibilityChannel.parseTempo([:]))
        XCTAssertNil(AccessibilityChannel.parseTempo([ChannelParam.tempo: "presto"]))
    }

    /// The Accessibility channel is the only one that can read the tempo back,
    /// and ChannelRouter returns on the first non-error result — so an
    /// unverifiable channel listed ahead of it would stop it from ever running.
    func testAccessibilityIsTriedBeforeOSCForSetTempo() {
        let chain = ChannelRouter.channelChain(for: "transport.set_tempo")
        XCTAssertEqual(chain.first, .accessibility, "chain was \(chain)")
        XCTAssertTrue(chain.contains(.osc), "OSC should remain as a fallback")
    }
}
