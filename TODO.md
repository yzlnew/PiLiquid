# Pi Liquid roadmap

Last reviewed: 2026-07-13.

Pi Liquid is a native macOS workspace built on top of the `pi --mode rpc`
protocol. This file tracks remaining product gaps only; shipped capabilities
are summarized in [README.md](README.md).

Legend: 🟢 fully backed by the current RPC protocol · 🟡 combines RPC with local
macOS/git/filesystem work · 🔴 requires a mostly native implementation.

## Shipped foundation

- Native streaming transcript, reasoning disclosures, tool cards, approvals,
  notifications, retries, compaction, and session statistics
- Markdown, tables, copyable code, KaTeX formulas, and Mermaid diagrams
- Project/session search, resume, rename, pin, archive, clone, fork, timeline,
  back/forward navigation, and warm project switching
- Slash commands, prompts, skills, file mentions, image attachments, shell mode,
  Plan Mode, model/reasoning controls, and steer/follow-up queues
- Inline tool diffs, per-turn git review and revert, project file browser, and
  isolated worktree sessions with merge-back/discard
- Share-as-image, raw-session sharing, HTML export, and English/Chinese UI

## P0 — deepen the existing workspace

- [ ] **Raw message inspector** 🟢 — show `get_messages` JSON, message metadata,
  stop reasons, and per-message usage for debugging agent behavior.
- [ ] **Usage and cost breakdown** 🟢 — expand the compact context card into
  per-model totals, cache read/write usage, and turn-level cost history using
  `get_session_stats` and message usage.
- [ ] **Native file preview** 🔴 — extend the existing Files inspector from a
  lazy tree that opens external apps into an in-app text/Markdown/code preview.
  Editing can remain out of scope for the first iteration.
- [ ] **Git operations panel** 🔴 — build on `GitService` and turn review with
  status, stage/unstage, commit, branch, pull/push, and optional `gh` actions.

## P1 — larger coding workflows

- [ ] **Integrated terminal** 🔴 — PTY-backed terminal tabs for interactive
  commands. This is distinct from the existing one-shot `bash` RPC mode.
- [ ] **Multi-agent worktree runs** 🟡 — launch several isolated sessions from
  one prompt, compare their outputs/diffs, and choose one result to merge.
  Single isolated worktree sessions already ship.
- [ ] **Inline review comments** 🔴 — attach draft comments to diff lines or
  files, collect them into a review prompt, and send them back to the agent.
- [ ] **Multiple windows or session tabs** 🔴 — support several foreground
  conversations without losing the current project/session navigation model.
- [ ] **Branch visualization** 🟡 — turn the current timeline fork picker into a
  visible session tree across branches and clones.

## P2 — polish and distribution

- [ ] **Signed and notarized releases** 🟡 — automate universal archives,
  signing, notarization, checksums, and GitHub Release publishing.
- [ ] **Accessibility audit** 🔴 — VoiceOver labels/order, keyboard-only flows,
  contrast, reduced motion, and Dynamic Type behavior across every surface.
- [ ] **Performance telemetry for local builds** 🔴 — optional developer-only
  signposts around streaming, WKWebView layout, file indexing, and git capture.
- [ ] **Floating mini-chat** 🔴 — an optional compact always-on-top window for
  quick prompts without opening the full workspace.

## Non-goals for now

- Web, PWA, mobile, or a cross-platform Electron version
- SSH/cloud-hosted project access and tunnel management
- A large custom theme marketplace; Pi Liquid follows system appearance
- Replacing `pi`'s provider/authentication configuration inside the app
- Treating Plan Mode or worktrees as a security sandbox

## Implementation notes

- `RPCProtocol.swift` already decodes compaction, retry, and extension-error
  events; `ChatModel` surfaces them as transcript notices and state.
- `FileIndex`, `GitService`, `WorktreeService`, and the Review/Files inspector
  are the intended foundations for the P0 and P1 workspace items above.
- WKWebView rows must never be resized or moved frame-by-frame during animation.
  Transcript and inspector layout changes should snap whenever possible.
