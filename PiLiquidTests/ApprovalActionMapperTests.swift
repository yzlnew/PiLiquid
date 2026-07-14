import Testing
import Foundation
@testable import PiLiquid

/// Notification-action mapping: an approval dialog must round-trip through a
/// notification's buttons without ever answering with the wrong option.
struct ApprovalActionMapperTests {

    @Test func confirmDialogGetsApproveAndDeny() {
        let actions = ApprovalActionMapper.actions(forMethod: "confirm", options: [])
        #expect(actions.map(\.id) == ["confirm:yes", "confirm:no"])
    }

    @Test func selectDialogMapsOptionsCappedAtFour() {
        let options = ["Allow once", "Always allow", "Deny", "Ask later", "Fifth"]
        let actions = ApprovalActionMapper.actions(forMethod: "select", options: options)
        #expect(actions.count == 4)
        #expect(actions.map(\.title) == ["Allow once", "Always allow", "Deny", "Ask later"])
        #expect(actions.map(\.id) == ["select:0", "select:1", "select:2", "select:3"])
    }

    /// Free-text dialogs can't be answered from a notification — no buttons.
    @Test func inputAndEditorDialogsGetNoActions() {
        #expect(ApprovalActionMapper.actions(forMethod: "input", options: []).isEmpty)
        #expect(ApprovalActionMapper.actions(forMethod: "editor", options: []).isEmpty)
    }

    @Test func repliesRoundTrip() {
        let options = ["a", "b", "c"]
        #expect(ApprovalActionMapper.reply(forActionID: "confirm:yes", options: []) == .confirm(true))
        #expect(ApprovalActionMapper.reply(forActionID: "confirm:no", options: []) == .confirm(false))
        #expect(ApprovalActionMapper.reply(forActionID: "select:2", options: options) == .select("c"))
    }

    /// Out-of-range indices and the system identifiers (default click, dismiss)
    /// must never produce a dialog reply.
    @Test func unknownOrSystemActionIDsProduceNoReply() {
        #expect(ApprovalActionMapper.reply(forActionID: "select:9", options: ["a"]) == nil)
        #expect(ApprovalActionMapper.reply(forActionID: "select:-1", options: ["a"]) == nil)
        #expect(ApprovalActionMapper.reply(forActionID: "com.apple.UNNotificationDefaultActionIdentifier", options: ["a"]) == nil)
        #expect(ApprovalActionMapper.reply(forActionID: "com.apple.UNNotificationDismissActionIdentifier", options: ["a"]) == nil)
    }

    /// Every action id the mapper hands out must map back to a reply — a button
    /// that silently does nothing would leave the dialog hanging forever.
    @Test func everyIssuedActionMapsBack() {
        let options = ["x", "y"]
        for method in ["confirm", "select"] {
            for action in ApprovalActionMapper.actions(forMethod: method, options: options) {
                #expect(ApprovalActionMapper.reply(forActionID: action.id, options: options) != nil)
            }
        }
    }
}
