# InkShelf project state

This file is a compact, version-controlled handoff for new Codex sessions. It is
context, not a substitute for inspecting the current code and Git history.

## Product and repository

- Product: 墨架 InkShelf, a production-oriented SwiftUI local novel reader.
- Repository: `https://github.com/572787871/InkShelf` (public).
- Active integration branch: `agent/unsigned-ipa-artifact`.
- Existing draft PR: PR #2 into `main`.
- CI workflow: `.github/workflows/ios.yml`; it runs the project build/tests,
  builds an unsigned device app, packages an unsigned IPA, and uploads it as an
  Actions artifact.
- The remote Linux workspace cannot run Xcode or perform iPhone validation.

## Important implementation map

- `InkShelf/Views/BookshelfView.swift`
  - shelf grid/list UI, import entry, reader presentation and close gesture
  - persistent narration floater integration
- `InkShelf/Views/ReaderView.swift`
  - reader state, pagination integration, chrome/settings, narration UI and
    visible-page/narration-page coordination
- `InkShelf/Views/InteractivePageTurnView.swift`
  - UIKit/Core Animation page curl and cover-turn engines, caches and gestures
- `InkShelf/Services/ReadAloudService.swift`
  - AVSpeechSynthesizer session, sentence highlighting, background audio,
    chapter timeline, MediaPlayer now-playing metadata and remote commands
- `InkShelf/Models/ReadAloudRoles.swift`
  - local dialogue attribution, stable character/unknown speaker assignments,
    and persisted read-aloud voice preferences
- `InkShelf/Views/ReadAloudSettingsView.swift`
  - automatic character voice, unknown-dialogue alternation, speed, narrator,
    and three character voice-slot settings
- `InkShelf/Services/LibraryStore.swift`
  - books, reading progress, persistence, import result/error state
- `InkShelf/Services/NovelImporter.swift`
  - security-scoped import, sandbox copying, encoding detection and parsing
- `InkShelf/Views/BookCoverView.swift`
  - shelf cover rendering; the App must not overlay title text or decorative
    words/symbols inside the default cover image
- `InkShelfTests/NovelParserTests.swift`
  - parser, pagination transactions, navigation decisions, timeline and related
    regression tests

## Current behavior contracts

### Reader presentation

- Reader opens upward from the bottom and closes downward.
- Open and close use `.easeInOut(duration: 0.34)` and release their transition
  lock after 0.36 seconds.
- Every presentation receives a new identity so stale `@State` from the previous
  reader instance is not reused.
- The initial pagination pass prioritizes the live narration location when the
  opened book owns the active narration session.
- Left-edge dismissal uses a narrow pure-SwiftUI drag target below the top bar;
  the prior `UIScreenEdgePanGestureRecognizer` bridge was removed after a
  reported real-device crash.

### Narration and page browsing

- Narration and manual browsing are deliberately decoupled.
- A manual page turn, directory jump, or progress browsing action does not move
  the speech queue to that page.
- “从本页听” starts the visible page. A paragraph play button starts that
  paragraph.
- “原进度” returns to `ReadAloudService.currentPageLocation` and keeps the
  current sentence playing.
- If the user browses away, narration continues through its own subsequent
  pages without forcing the visible page back.
- If the visible page still matches narration, finishing a page can perform the
  normal automatic page-turn animation.
- Opening the active book from either its shelf card or the floating cover must
  land on the current narration page.
- The floating circular cover opens the narrated book. It rotates while playing,
  freezes at its current angle while paused, and resumes from that angle.
- Background audio and Apple lock-screen/Control Center controls are supported.
- Automatic character voices are local-only: the current chapter is analyzed
  lazily for quoted dialogue and explicit speaking verbs, then named characters
  are assigned stable voice slots. Ambiguous dialogue can alternate between
  fallback slots without inventing a character identity.
- Read-aloud settings are available from the app Settings screen and persist on
  device. In the reader, the bottom “朗读” action first opens the settings sheet;
  narrator and role voices can be previewed there, and “开始朗读” starts from
  the visible page. Voice and speed changes apply to subsequent utterances
  without retargeting the active narration session.
- Automatic visible-page turns are accepted transactionally by the curl/cover
  engines. Programmatic turns have engine and reader-level completion fallbacks
  so a missing UIKit animation callback cannot leave narration waiting at the
  end of a page or keep the page-turn transaction locked.
- At a narrated page boundary, the speech session advances to the next page
  before the visual page-turn animation completes. The animation can therefore
  never block the next utterance; its reader-level fallback still commits the
  visible page after 0.85 seconds when UIKit does not report completion.
- Reader page capacity uses a lightweight line-aware pass over the source with
  the visible text area, actual font metrics, line spacing, explicit newlines,
  chapter-title allowance, the read-aloud paragraph indent, and three safety rows.
  Do not run TextKit once per page: imported books can exceed 20,000 pages and
  reader opening must remain responsive. Narration must never consume text
  clipped below the page before a turn.
- Pagination never snaps backward to a paragraph or punctuation boundary. A
  paragraph may span pages, and every character that does not fit on the current
  page must continue at the beginning of the next page.
- Pagination reserves the read-aloud control indent only on the first line of a
  page or paragraph; wrapped continuation lines use the full text width so their
  last row does not leave artificial empty character slots.
- Pages retain those conservative text boundaries but distribute unused vertical
  space into capped per-page line spacing, so short pages visually reach toward
  the footer without pulling hidden text back from the following page.
- Reader appearance controls use grouped cards with coordinated theme/background
  previews, brightness, precise font-size controls, named line-spacing presets
  plus numeric sliders, page margins, font, page-turn style, and screen-awake
  state. Layout reset restores only typography defaults.
- Page-turn controller caches compare retained `ReaderPage` content, not only
  page locations. Repagination can keep the same chapter/page IDs while changing
  their text boundaries, and stale cached text must never diverge from speech.
- Natural completion at the end of the book clears the narration session
  without re-entering `AVSpeechSynthesizer.stopSpeaking` from its utterance
  completion callback.

### Shelf and covers

- Shelf supports grid and list layouts.
- Grid chapter progress uses the compact complete form such as
  `2058章/2631章` and must not truncate behind the ellipsis menu.
- The plus button directly opens the document picker.
- Default cover images are shown without App-rendered title, author, “墨架典藏”,
  lines, dots, or decorative symbol overlays. The title remains below the cover.

### Import

- Import supports TXT/Markdown/EPUB according to `NovelImporter.supportedTypes`.
- Selected provider URLs must be accessed as security-scoped resources, copied
  into the sandbox while access is valid, then parsed from the sandbox copy.
- TXT decoding includes UTF-8/BOM, UTF-16 LE/BE, GBK and GB18030 fallbacks.
- Import failures must be visible to the user and must not silently return to the
  shelf.

## Verification workflow

1. Run `git diff --check` and inspect the exact diff.
2. Commit only request-related files and push the active branch.
3. Find the run with:
   `gh run list --branch agent/unsigned-ipa-artifact --limit 3 --json databaseId,headSha,status,conclusion,url`.
4. Use bounded `gh run view <id> --json status,conclusion,jobs,url` checks.
5. On success, report the run and unsigned IPA artifact. On failure, inspect the
   failed step logs and fix before reporting completion.

## Real-device checks still matter

Actions proves compilation and automated tests, not touch feel, page-curl visual
quality, AVSpeech behavior under iOS interruptions, background playback, or crash
freedom. Report those as requiring the user's signed IPA/iPhone verification.
