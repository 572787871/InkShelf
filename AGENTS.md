# InkShelf Codex guidance

These instructions are the durable handoff for every Codex session working in
this repository. Read [PROJECT_STATE.md](PROJECT_STATE.md) before planning or
editing, then verify its potentially stale details against the working tree.

## Session startup

1. Run `git status -sb` and `git log -5 --oneline`.
2. Stay on `agent/unsigned-ipa-artifact` unless the user explicitly requests a
   different branch.
3. Read `PROJECT_STATE.md`, then inspect the relevant implementation instead of
   assuming the document is perfectly current.
4. For GitHub state, use bounded queries such as
   `gh run list --branch agent/unsigned-ipa-artifact --limit 3`; never use
   `gh run watch` or an indefinite polling loop.

## Working agreements

- Communicate with the user in Chinese unless they request another language.
- Make the smallest change that fulfills the current request. Preserve unrelated
  UI, reader behavior, import behavior, narration, persistence, and user edits.
- Use `apply_patch` for source and documentation edits.
- Preserve a dirty worktree and stage only files that belong to the request.
- The repository is public: `572787871/InkShelf`.
- Push normal product changes to `agent/unsigned-ipa-artifact`; the existing
  draft PR is the continuing integration PR.
- After a change, run `git diff --check`, commit intentionally, push, and inspect
  the `iOS` GitHub Actions workflow. It builds/tests and uploads an unsigned IPA.
- This Linux environment has no local Xcode toolchain. Do not claim simulator or
  real-device verification. Clearly distinguish static checks, Actions results,
  and tests the user still needs to perform on an iPhone.
- Do not install a Skill merely to preserve project context. This file and
  `PROJECT_STATE.md` are the repository-level continuity mechanism.

## Product invariants

- Manual page browsing during narration must not retarget narration. “从本页听”
  and an explicit tap on a visible segment's play button may change the
  narration start; passive page turns and progress browsing may not.
- “原进度” returns the visible reader to the page currently being narrated
  without stopping or restarting speech.
- Opening the narrated book from its shelf cover or the floating player must
  prioritize the live narration page over the saved shelf page.
- Reader page animations must not mutate committed progress until completion.
- Reader chrome and settings panels do not participate in page-turn animations.
- Opening and closing the reader use matching vertical `.easeInOut` animations
  with a duration of 0.34 seconds and unlock after 0.36 seconds.
- Keep background narration, lock-screen controls, highlighting, and chapter
  timelines working when reader UI changes.
- Never claim a crash is fixed on a real device until the user verifies the IPA.

## Maintaining continuity

Update `PROJECT_STATE.md` when architecture, important behavior, build workflow,
branch strategy, or known verification status changes. Do not fill it with a
verbatim chat transcript or secrets. At the start of a new session, current code
and GitHub state override stale status text in that file.
