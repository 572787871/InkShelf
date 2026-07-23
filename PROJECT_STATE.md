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
- `InkShelf/Views/AudiobookPlayerView.swift`
  - dedicated full-screen audiobook UI with transcript following/manual scroll,
    chapter directory, speed/options, chapter controls and scrub timeline
- `InkShelf/Views/InteractivePageTurnView.swift`
  - UIKit/Core Animation page curl and cover-turn engines, caches and gestures
- `InkShelf/Services/ReadAloudService.swift`
  - automatic audiobook session, persisted whole-book smart casting, cloud/local TTS
    orchestration, rolling speech pre-generation, transcript position,
    background audio, chapter timeline and MediaPlayer controls
- `InkShelf/Services/AudiobookSpeechKit.swift`
  - MiMo and OpenAI-compatible speech clients, AI chapter role analysis,
    automatic role casting, Keychain credential storage and audio playback
- `InkShelf/Services/NovelCastStore.swift`
  - content-signed per-book/per-chapter role assignments and gender metadata;
    source ranges remap onto the current pagination without losing split text
- `InkShelf/Services/ZipVoiceKit.swift` and `ZipVoiceTTSBridge.{h,mm}`
  - official ZipVoice model download/install, reference-voice profiles,
    Swift-to-sherpa-onnx bridge and iPhone ONNX inference
- `InkShelf/Services/LocalVoiceKit.swift` and `InkShelf/Views/LocalVoiceViews.swift`
  - authorized App recording / Files import, shared audio preprocessing,
    simulated-voice storage, quality checks, trimming and voice management UI
- `InkShelf/Models/ReadAloudRoles.swift`
  - enhanced offline dialogue attribution (quotes, speech/action verbs,
    honorifics, context and turn continuity), stable character/unknown speaker
    assignments, and persisted provider/playback preferences
- `InkShelf/Views/ReadAloudSettingsView.swift`
  - homepage-only cloud speech-engine selection, service URL/model/API key directly
    below the engine, automatic/per-character voice selection, privacy, speed and
    preview UI; local model and role-analysis controls are intentionally absent
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
- “从本页听” starts the visible page. While that book owns an active narration
  session, long-pressing visible paragraph text explicitly retargets narration
  to that paragraph. Paragraph play/pause buttons and their first-line gutter
  are deleted; the normal text width is used before and during narration.
- “原进度” returns to `ReadAloudService.currentPageLocation` and keeps the
  current sentence playing.
- If the user browses away, narration continues through its own subsequent
  pages without forcing the visible page back.
- If the visible page still matches narration, finishing a page can perform the
  normal automatic page-turn animation.
- Opening the active book from its shelf card must land on the current narration
  page. The floating circular cover opens the dedicated audiobook screen. It rotates while playing,
  freezes at its current angle while paused, and resumes from that angle.
- Background audio and Apple lock-screen/Control Center controls are supported.
- Role attribution can run as an enhanced, fully offline whole-book parser or a
  resumable AI director through MiMo/OpenAI-compatible endpoints. Both identify
  first/third-person narration and named roles and save every completed chapter
  immediately. AI analysis falls back per chapter to the same local parser when
  credentials, network or the endpoint are unavailable, and playback never
  waits for AI. Each chapter is content-signed and assignments use source UTF-16
  ranges, so font or pagination changes do not invalidate the cast. The prior
  downloadable MLX/Qwen model remains removed.
- Whole-book local/AI analysis updates one progress row while it is running; it
  does not continually expand the settings form with every newly found character.
  The final settings summary shows only the detected count.
- Automatic voice selection keeps narration and named characters stable. Users
  can instead separately choose first-person narrator, third-person narrator,
  unknown-character and every detected named-character voice; the old unified
  voice mode is removed. MiMo exposes its eight published preset IDs. Local
  ZipVoice accepts WAV/M4A/MP3/AAC/CAF, coordinates security-scoped Files URLs,
  and supports authorized App recording. Both creation paths use one
  `AudioPreprocessor` to decode, select/crop at most 30 seconds, convert to mono,
  read the loaded sherpa model's actual output rate, trim edge silence, measure
  effective speech, normalize conservatively, and flag clipping, low level or
  excessive silence. Five curated full-utterance 24 kHz references (three
  female, two male) remain from the former 103-entry catalog, presented under
  product-facing Chinese names alongside user-created voices.
- User-created voices live under
  `Application Support/VoiceProfiles/{voice-id}/` with relative paths only:
  original audio, `reference.wav`, `reference.txt`, `preview.wav`, `profile.json`
  and `consent.json`. Legacy flat user imports migrate on first launch. Recording
  or import requires explicit ownership/authorization confirmation; the App
  does not provide a celebrity or platform-voice cloning workflow.
- Apple system voices, runtime Kokoro/VITS packages and the old model store are
  not used.
  Speech can use MiMo chat audio, a configurable OpenAI-compatible
  `/audio/speech` service, or ZipVoice through sherpa-onnx + ONNX Runtime on the
  iPhone. The official bilingual INT8 model/vocoder is downloaded from the
  sherpa-onnx release and checksum-verified instead of being bundled in the IPA.
- While a speech block is playing, up to three following blocks are synthesized
  into a rolling page-and-sentence-keyed buffer. The immediately following audio
  is decoded before handoff, and a silent audio-session continuity bed keeps
  audiobook background execution alive while an uncached block is generated. If pagination
  cuts through a sentence, the two page fragments are synthesized as one audio
  request and the visible/session page advances during that audio instead of
  inserting a new utterance boundary.
- For local ZipVoice, buffered blocks contain at most six adjacent same-speaker
  sentences / 360 UTF-16 units, including the next page when space allows. This
  reduces repeated model startup overhead and gives rolling generation more
  spoken runway. The distilled model uses the official four-step inference setting,
  pre-generates following blocks while audio plays, and keeps a bounded
  in-memory replay cache. Edge-silence trimming, DC correction, bounded gain and
  short fades remain; speaker changes retain intentional boundaries.
- The sherpa bridge keeps one ZipVoice engine, queries
  `SherpaOnnxOfflineTtsSampleRate`, caches decoded reference PCM, and uses the
  real generation progress callback for cancellation. Generated previews are
  stored with their profiles; book fragments use a bounded memory cache plus a
  SHA-256-keyed disk cache that never puts novel text in filenames. A memory
  warning retains only the currently active reference cache.
- API keys are stored in the iOS Keychain and text upload is disabled until the
  user explicitly consents. Local ZipVoice playback needs no network after its
  model download; whole-book smart analysis is optional, resumable network work
  and cached chapters remain available offline.
- Read-aloud settings are available only from the homepage top-right Settings
  screen. The settings surface exposes cloud speech engines and places the API
  key directly below the engine fields; local model and AI/offline role-analysis
  controls are not shown. The reader's bottom “朗读” action opens the dedicated audiobook screen;
  that screen hides the floating controller and provides cover, title/chapter,
  following transcript with manual scrolling, directory, speed/options, chapter
  skip, pause/play, scrubbing and time labels. Closing it leaves narration running
  and restores the floating controller. When configuration is incomplete it only
  directs the user back to homepage Settings. Connection testing synthesizes one
  short narrator sample.
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
  chapter-title allowance and three safety rows.
  Do not run TextKit once per page: imported books can exceed 20,000 pages and
  reader opening must remain responsive. Narration must never consume text
  clipped below the page before a turn.
- Pagination never snaps backward to a paragraph or punctuation boundary. A
  paragraph may span pages, and every character that does not fit on the current
  page must continue at the beginning of the next page.
- Reader pagination and rendering both use the full text width; narration no
  longer changes paragraph indentation.
- Pages retain those conservative text boundaries but distribute unused vertical
  space into capped per-page line spacing, so short pages visually reach toward
  the footer without pulling hidden text back from the following page.
- The reading page no longer renders narration highlights. Spoken-position
  emphasis and automatic text following belong only to the dedicated audiobook
  transcript, so normal reading layout remains visually untouched.
- Reader appearance controls use grouped cards with coordinated theme/background
  previews, brightness, precise font-size controls, named line-spacing presets
  plus numeric sliders, page margins, font, page-turn style, and screen-awake
  state. Layout reset restores only typography defaults.
- Page-turn controller caches compare retained `ReaderPage` content, not only
  page locations. Repagination can keep the same chapter/page IDs while changing
  their text boundaries, and stale cached text must never diverge from speech.
- Natural completion at the end of the book clears the narration session after
  the final generated audio finishes playback.

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

## Agent module routing

The global Codex skills `reader`, `audio`, `library`, `ui`, and `build` provide
focused context for long-term work. Use the smallest relevant set and combine
them for cross-domain changes:

- Reader changes: `$reader` + `$ui`; add `$audio` when narration location or
  playback coordination is involved.
- Audio changes: `$audio` + `$reader` for page/session coupling; add `$ui` for
  the audiobook screen or transcript interaction.
- Library changes: `$library` + `$reader` for progress/pagination; add `$ui` for
  shelf and import presentation.
- Any visual or animation change: `$ui` plus the owning domain skill.
- Every change that needs compilation, tests, CI, an IPA, or release evidence:
  `$build` (and `$ios-agent-verification` when broader Apple-platform safety
  checks are needed).

Sync and StoreKit skills are intentionally deferred until those product domains
have real implementation files and persistence contracts.

## Real-device checks still matter

Actions proves compilation and automated tests, not touch feel, page-curl visual
quality, network-provider compatibility, audio interruptions, background
playback, or crash freedom. Report those as requiring signed IPA/iPhone
verification.
