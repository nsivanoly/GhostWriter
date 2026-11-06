import Foundation

// MARK: - Meeting Titler
//
// Finds notes still carrying the placeholder title the recorder stamps on
// ("Meeting 2026-11-03_14-05-09") and gives them a real one, using the same
// title the end-of-meeting refinement would have produced. One place for both
// the single-note button and the bulk "Title all" action.

enum MeetingTitler {

    /// Whether `title` is an auto-generated placeholder ("Meeting <timestamp>",
    /// "Dictation <timestamp>", or empty) rather than a name someone chose.
    static func isDefault(_ title: String) -> Bool {
        let t = title.trimmingCharacters(in: .whitespacesAndNewlines)
        if t.isEmpty { return true }
        return t.range(of: #"^(Meeting|Dictation)[ _]\d{4}-\d{2}-\d{2}[_ T]\d{2}[-:]\d{2}([-:]\d{2})?$"#,
                       options: .regularExpression) != nil
    }

    enum Outcome: Equatable {
        case titled(String)
        case failed(String)
    }

    /// Generate a title from the note's transcript and write it to the file's
    /// front-matter and the Catalog row. Needs the cloud model (a key and not
    /// Local-only mode); returns a human-readable reason otherwise.
    @MainActor
    static func generate(for fileURL: URL, using polisher: TextPolisher = TextPolisher()) async -> Outcome {
        if AppSettings.shared.localOnlyMode { return .failed("Titles need the cloud model — turn off Local-only mode.") }
        guard let transcript = MeetingNotesWriter().transcriptText(of: fileURL),
              MeetingRefinery.dialogueLength(of: transcript) > 80 else {
            return .failed("Not enough conversation to title.")
        }
        let facts = await polisher.extractMeetingFacts(
            transcript: transcript, includeTitle: true, includePeople: false, fields: [])
        guard !facts.title.isEmpty else { return .failed("Couldn't generate a title — check your API key and connection.") }
        apply(facts.title, to: fileURL)
        return .titled(facts.title)
    }

    /// Write `title` to the note's front-matter and Catalog row (kept in sync).
    @MainActor
    static func apply(_ title: String, to fileURL: URL) {
        MeetingNotesWriter.setFrontMatterTitle(title, to: fileURL)
        CatalogStore.shared.renameNote(
            relativePath: AppSettings.shared.relativePath(of: fileURL), to: title)
    }
}
