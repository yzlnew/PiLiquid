import Testing
import Foundation
@testable import PiLiquid

/// Unified-diff parsing: the turn-review panel is only as truthful as this
/// parser, so every change kind git emits gets a case here.
struct GitDiffParserTests {

    private let multiFileDiff = """
    diff --git a/src/main.swift b/src/main.swift
    index 1111111..2222222 100644
    --- a/src/main.swift
    +++ b/src/main.swift
    @@ -1,3 +1,3 @@
     line1
    -old
    +new
    @@ -10,2 +10,3 @@
     ctx
    +added
     ctx2
    diff --git a/new.txt b/new.txt
    new file mode 100644
    index 0000000..1111111
    --- /dev/null
    +++ b/new.txt
    @@ -0,0 +1,2 @@
    +a
    +b
    diff --git a/gone.txt b/gone.txt
    deleted file mode 100644
    index 1111111..0000000
    --- a/gone.txt
    +++ /dev/null
    @@ -1,1 +0,0 @@
    -bye
    diff --git a/old name.txt b/new name.txt
    similarity index 100%
    rename from old name.txt
    rename to new name.txt
    diff --git a/img.png b/img.png
    index 1111111..2222222 100644
    Binary files a/img.png and b/img.png differ
    """

    @Test func parsesEveryChangeKind() {
        let files = GitDiffParser.parse(multiFileDiff)
        #expect(files.count == 5)

        let modified = files[0]
        #expect(modified.path == "src/main.swift")
        #expect(modified.change == .modified)
        #expect(modified.hunks.count == 2)
        #expect(modified.added == 2)
        #expect(modified.removed == 1)

        let added = files[1]
        #expect(added.path == "new.txt")
        #expect(added.change == .added)
        #expect(added.added == 2)
        #expect(added.removed == 0)

        let deleted = files[2]
        #expect(deleted.path == "gone.txt")
        #expect(deleted.change == .deleted)
        #expect(deleted.removed == 1)

        let renamed = files[3]
        #expect(renamed.path == "new name.txt")
        #expect(renamed.change == .renamed(from: "old name.txt"))
        #expect(renamed.hunks.isEmpty)   // pure rename, no content change

        let binary = files[4]
        #expect(binary.path == "img.png")
        #expect(binary.isBinary)
        #expect(binary.hunks.isEmpty)
    }

    @Test func hunkLineKindsAndTextSurvive() {
        let files = GitDiffParser.parse(multiFileDiff)
        let lines = files[0].hunks[0].lines
        #expect(lines.map(\.kind) == [.context, .removed, .added])
        #expect(lines.map(\.text) == ["line1", "old", "new"])
    }

    /// git quotes paths containing spaces or non-ASCII; the panel must show the
    /// real path, not the quoted form.
    @Test func unquotesQuotedPaths() {
        let diff = """
        diff --git "a/sp ace.txt" "b/sp ace.txt"
        index 1111111..2222222 100644
        --- "a/sp ace.txt"
        +++ "b/sp ace.txt"
        @@ -1 +1 @@
        -x
        +y
        """
        let files = GitDiffParser.parse(diff)
        #expect(files.count == 1)
        #expect(files[0].path == "sp ace.txt")
    }

    @Test func noNewlineMarkerIsPresentationOnly() {
        let diff = """
        diff --git a/f.txt b/f.txt
        index 1111111..2222222 100644
        --- a/f.txt
        +++ b/f.txt
        @@ -1 +1 @@
        -x
        \\ No newline at end of file
        +y
        \\ No newline at end of file
        """
        let files = GitDiffParser.parse(diff)
        #expect(files[0].added == 1)
        #expect(files[0].removed == 1)
        #expect(files[0].hunks[0].lines.count == 2)
    }

    @Test func emptyInputParsesToNothing() {
        #expect(GitDiffParser.parse("").isEmpty)
    }

    @Test func turnDiffTotalsSumAcrossFiles() {
        let files = GitDiffParser.parse(multiFileDiff)
        let turn = TurnDiff(id: "t", baseTree: "base", files: files)
        #expect(turn.totalAdded == 4)    // 2 modified + 2 new
        #expect(turn.totalRemoved == 2)  // 1 modified + 1 deleted
    }
}
