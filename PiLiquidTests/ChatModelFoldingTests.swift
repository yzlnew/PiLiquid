import Testing
import Foundation
@testable import PiLiquid

/// Event-folding regressions: captured RPC sequences replayed through the real
/// `ChatModel.handle` path, asserting the transcript/UI state the views render.
@MainActor
struct ChatModelFoldingTests {

    @Test func streamedTurnFoldsIntoOneAssistantBubble() {
        let model = ChatModel()
        replay([
            Fixture.agentStart,
            Fixture.turnStart,
            Fixture.userMessageStart,
            Fixture.assistantMessageStart,
            Fixture.assistantUpdateBothKeys,
            Fixture.assistantUpdatePartialOnly,
            Fixture.assistantMessageEnd,
            Fixture.turnEnd,
            Fixture.agentEnd,
        ], into: model)

        #expect(!model.isStreaming)
        #expect(model.runStatus == .succeeded)
        #expect(model.transcript.count == 1)
        guard case .assistant(let entry) = model.transcript.first else {
            Issue.record("expected a single assistant entry"); return
        }
        #expect(!entry.isStreaming)
        #expect(entry.segments == [.thinking("the user wants a greeting"), .text("hello")])
    }

    /// The plan-mode context (role `custom`) and echoed user message must not
    /// create bubbles — only assistant messages do.
    @Test func nonAssistantMessagesCreateNoBubbles() {
        let model = ChatModel()
        replay([Fixture.agentStart, Fixture.userMessageStart, Fixture.planContextMessageStart], into: model)
        #expect(model.transcript.isEmpty)
    }

    /// The silent-stall regression: agent running, model response not started
    /// (stalled API call / between tool turns) → the transcript must know to
    /// show a waiting indicator, else the app looks dead.
    @Test func awaitingModelOutputWhileNoAssistantBubble() {
        let model = ChatModel()
        replay([Fixture.agentStart, Fixture.userMessageStart, Fixture.planContextMessageStart], into: model)
        #expect(model.isStreaming)
        #expect(model.awaitingModelOutput)

        // First assistant token: the bubble takes over the indicator role.
        replay([Fixture.assistantMessageStart], into: model)
        #expect(!model.awaitingModelOutput)

        // Turn over: nothing to wait for.
        replay([Fixture.assistantMessageEnd, Fixture.agentEnd], into: model)
        #expect(!model.awaitingModelOutput)
    }

    @Test func erroredTurnShowsErrorAndFailedStatus() {
        let model = ChatModel()
        replay([
            Fixture.agentStart,
            Fixture.assistantMessageStart,
            Fixture.assistantMessageEndError,
            Fixture.agentEnd,
        ], into: model)

        #expect(model.runStatus == .failed)
        // The empty placeholder bubble is dropped; the failure surfaces as an
        // error notice (this is the only place the user learns the turn died).
        let notices = model.transcript.compactMap { item -> NoticeEntry? in
            if case .notice(let n) = item { return n }
            return nil
        }
        #expect(notices.contains { $0.kind == .error && $0.text.contains("429") })
    }

    // MARK: - Extension status surface (plan mode)

    @Test func planStatusIngestsAnsiStrippedAndToggles() {
        let model = ChatModel()
        replay([Fixture.planStatusOn], into: model)
        #expect(model.isPlanActive)
        #expect(model.planStatusText == "⏸ plan")   // ANSI SGR stripped

        replay([Fixture.planStatusOff], into: model)
        #expect(!model.isPlanActive)
        #expect(model.planStatusText == nil)
    }

    @Test func latestPlanTextIsLastAssistantText() {
        let model = ChatModel()
        #expect(model.latestPlanText == nil)   // nothing to execute yet
        replay([
            Fixture.agentStart,
            Fixture.assistantMessageStart,
            Fixture.assistantMessageEnd,
            Fixture.agentEnd,
        ], into: model)
        #expect(model.latestPlanText == "hello")   // text only, thinking excluded
    }

    /// A stalled model call must eventually flip `modelStalled` (the UI hint),
    /// and any inbound line must clear it immediately.
    @Test func stallWatchdogFlagsSilenceAndClearsOnActivity() async throws {
        let model = ChatModel()
        model.stallAfter = 0.2   // shrink the 45s production threshold
        replay([Fixture.agentStart, Fixture.userMessageStart], into: model)
        #expect(!model.modelStalled)

        try await Task.sleep(for: .seconds(1.0))   // > stallAfter + poll interval
        #expect(model.modelStalled)

        // First sign of life clears the hint.
        replay([Fixture.assistantMessageStart], into: model)
        #expect(!model.modelStalled)

        replay([Fixture.assistantMessageEnd, Fixture.agentEnd], into: model)
        #expect(!model.modelStalled)
    }

    // MARK: - Session-name migration shim

    /// Old builds passed `--name <project folder>` for every new session; the
    /// poisoned name coming back through get_state must be ignored, or clicking
    /// a session renames it to the project in the sidebar.
    @Test func sessionNameEqualToProjectFolderIsIgnored() {
        #expect(ChatModel.adoptedSessionName("pi_liquid", projectFolderName: "pi_liquid") == nil)
        #expect(ChatModel.adoptedSessionName("my real name", projectFolderName: "pi_liquid") == "my real name")
        #expect(ChatModel.adoptedSessionName("", projectFolderName: "pi_liquid") == nil)
        #expect(ChatModel.adoptedSessionName(nil, projectFolderName: "pi_liquid") == nil)
    }
}
