import Testing
import Foundation
@testable import PiLiquid

/// End-to-end wiring for the turn-diff chip: replayed RPC events around a real
/// file change must produce a `turnDiffs` entry keyed by the transcript's final
/// assistant message — the exact condition `TranscriptView` renders the chip on.
@MainActor
struct TurnDiffWiringTests {

    private func waitForDiff(_ model: ChatModel, timeout: TimeInterval = 8) async throws {
        var waited = 0.0
        while model.turnDiffs.isEmpty && waited < timeout {
            try await Task.sleep(for: .milliseconds(100))
            waited += 0.1
        }
    }

    @Test func fileChangeDuringTurnYieldsKeyedDiff() async throws {
        let repo = try TempRepo(prefix: "wiring")
        defer { repo.destroy() }
        try repo.write("a.txt", "one\n")
        repo.commitAll()

        let model = ChatModel()
        model.adoptWorkingDirectoryForTesting(repo.url)
        #expect(model.isGitRepo)

        model.handle(inbound(Fixture.agentStart))
        // Give the detached base snapshot time to run *before* the "agent"
        // mutates the tree (in real turns the model call guarantees this gap).
        try await Task.sleep(for: .milliseconds(500))
        try repo.write("a.txt", "one\ntwo\n")
        replay([Fixture.assistantMessageStart, Fixture.assistantMessageEnd, Fixture.agentEnd], into: model)

        try await waitForDiff(model)
        #expect(model.turnDiffs.count == 1)
        let diff = try #require(model.turnDiffs.values.first)
        #expect(diff.files.map(\.path) == ["a.txt"])
        #expect(diff.totalAdded == 1)

        // The chip renders on `turnDiffs[group.finalAssistantID]` — the key must
        // be the transcript's final assistant entry.
        guard case .assistant(let entry)? = model.transcript.last(where: {
            if case .assistant = $0 { return true } else { return false }
        }) else {
            Issue.record("expected an assistant entry"); return
        }
        #expect(diff.id == entry.id)
    }

    @Test func cleanTurnStoresNoDiff() async throws {
        let repo = try TempRepo(prefix: "wiring-clean")
        defer { repo.destroy() }
        try repo.write("a.txt", "one\n")
        repo.commitAll()

        let model = ChatModel()
        model.adoptWorkingDirectoryForTesting(repo.url)
        model.handle(inbound(Fixture.agentStart))
        try await Task.sleep(for: .milliseconds(500))
        replay([Fixture.assistantMessageStart, Fixture.assistantMessageEnd, Fixture.agentEnd], into: model)

        try await Task.sleep(for: .seconds(1))   // give any (wrong) capture time to land
        #expect(model.turnDiffs.isEmpty)
    }
}
