import Testing
import Foundation
@testable import PiLiquid

/// The exact pi invocation matters: a stray flag can permanently poison session
/// files (`--name` did — pi persists it as the session's title forever).
@MainActor
struct LaunchConfigTests {

    @Test func newSessionPassesNoNameOrSessionFlags() {
        let manager = SessionManager(settings: AppSettings())
        let config = manager.launchConfig(url: URL(fileURLWithPath: "/tmp/proj"), resumeSessionFile: nil)
        #expect(config.extraArguments.isEmpty)
        #expect(config.resumeSessionFile == nil)
        // PiLaunchConfig has no session-name field at all any more; this guards
        // against reintroducing one through extraArguments.
        #expect(!config.extraArguments.contains("--name"))
    }

    @Test func resumePassesSessionFlag() {
        let manager = SessionManager(settings: AppSettings())
        let file = "/Users/example/.pi/agent/sessions/--proj--/2026.jsonl"
        let config = manager.launchConfig(url: URL(fileURLWithPath: "/tmp/proj"), resumeSessionFile: file)
        #expect(config.extraArguments == ["--session", file])
        #expect(config.resumeSessionFile == file)
        #expect(!config.extraArguments.contains("--name"))
    }
}
