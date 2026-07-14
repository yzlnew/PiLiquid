import Testing
import Foundation
@testable import PiLiquid

/// Wire-format decoding against captured pi 0.80.2 traffic. These catch a pi
/// upgrade (or a decoder edit) silently changing what the UI receives — the
/// failure mode is never a crash, it's an event quietly dropped.
struct RPCProtocolTests {

    @Test func assistantMessageStartDecodes() throws {
        guard case .event(.messageStart(let m)) = inbound(Fixture.assistantMessageStart) else {
            Issue.record("expected messageStart event"); return
        }
        #expect(m.role == "assistant")
        #expect(m.textSegments.isEmpty)   // content [] at stream start
    }

    /// pi 0.80.x sends `message_update` with a redundant top-level `message`.
    @Test func messageUpdateDecodesFromMessageKey() throws {
        guard case .event(.messageUpdate(let m)) = inbound(Fixture.assistantUpdateBothKeys) else {
            Issue.record("expected messageUpdate event"); return
        }
        #expect(m.textSegments == [.text("hel")])
    }

    /// If pi ever drops the top-level `message` (rpc.md is ambiguous), the
    /// decoder must fall back to `assistantMessageEvent.partial`. Dropping the
    /// event instead means streaming display goes blank for the whole turn.
    @Test func messageUpdateFallsBackToPartial() throws {
        guard case .event(.messageUpdate(let m)) = inbound(Fixture.assistantUpdatePartialOnly) else {
            Issue.record("update without top-level message was dropped"); return
        }
        #expect(m.textSegments == [.text("hello")])
    }

    /// Plan mode's injected context message has role `custom` and a *string*
    /// `content` — it must decode (not crash / not become assistant text).
    @Test func customRoleStringContentDecodes() throws {
        guard case .event(.messageStart(let m)) = inbound(Fixture.planContextMessageStart) else {
            Issue.record("expected messageStart event"); return
        }
        #expect(m.role == "custom")
        #expect(m.textSegments.count == 1)   // synthesized single text block
    }

    @Test func messageEndCarriesThinkingAndText() throws {
        guard case .event(.messageEnd(let m)) = inbound(Fixture.assistantMessageEnd) else {
            Issue.record("expected messageEnd event"); return
        }
        #expect(m.textSegments == [.thinking("the user wants a greeting"), .text("hello")])
        #expect(!m.isError)
    }

    @Test func erroredTurnSurfacesErrorMessage() throws {
        guard case .event(.messageEnd(let m)) = inbound(Fixture.assistantMessageEndError) else {
            Issue.record("expected messageEnd event"); return
        }
        #expect(m.isError)
        #expect(m.errorMessage == "429 rate limited")
        #expect(m.textSegments.isEmpty)
    }

    @Test func setStatusDecodesKeyAndAnsiText() throws {
        guard case .uiRequest(let req) = inbound(Fixture.planStatusOn) else {
            Issue.record("expected uiRequest"); return
        }
        #expect(req.method == "setStatus")
        #expect(req.statusKey == "plan-mode")
        #expect(req.statusText?.contains("⏸ plan") == true)
        #expect(req.statusText?.contains("\u{001B}") == true)   // ANSI arrives raw
        #expect(!req.isDialog)                                   // fire-and-forget
    }

    @Test func setStatusWithoutTextMeansClear() throws {
        guard case .uiRequest(let req) = inbound(Fixture.planStatusOff) else {
            Issue.record("expected uiRequest"); return
        }
        #expect(req.statusKey == "plan-mode")
        #expect(req.statusText == nil)
    }

    @Test func agentLifecycleEventsDecode() throws {
        if case .event(.agentStart) = inbound(Fixture.agentStart) {} else { Issue.record("agent_start") }
        if case .event(.agentEnd) = inbound(Fixture.agentEnd) {} else { Issue.record("agent_end") }
        if case .event(.turnStart) = inbound(Fixture.turnStart) {} else { Issue.record("turn_start") }
        if case .event(.turnEnd) = inbound(Fixture.turnEnd) {} else { Issue.record("turn_end") }
    }
}
