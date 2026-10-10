---
version: 1
slug: "sources-copilotprojectshost-pullrequestsview-swift"
primary_target: "Sources/CopilotProjectsPullRequests/PullRequestsView.swift"
related_targets: ["Sources/CopilotProjectsPullRequests/PullRequests.swift","Sources/CopilotProjectsPullRequests/PullRequestsPresentation.swift","Sources/CopilotProjectsPullRequests/PullRequestsModel.swift","Sources/CopilotProjectsPullRequests/PullRequestsWorkspace.swift","Sources/CopilotProjectsPullRequests/PullRequestsApplication.swift","Sources/CopilotProjectsHost/PullRequestsAppLauncher.swift","Sources/CopilotProjectsStyle/StudioStyle.swift","Tests/PullRequestsPresentationTests.swift","Tests/ResumableSessionsTests.swift"]
---

# Pull Requests: Goal Lanes

Mode: Operate. The one window of Copilot Pull Requests, a separate macOS app
nested in Copilot Projects with its own Dock icon and ⌘Tab entry (opened or
brought forward by Window ▸ Pull Requests, ⇧⌘P), showing the user's open pull
requests grouped by goal: PRs working toward one outcome, inferred
from the Copilot session that drives them (head-branch evidence in its transcript),
merged by shared head branch, and reassignable by hand. Scope: PRs in the chosen
owners only (a token list; empty means every owner). Attention: failing required checks, changes
requested, conflicts/behind, unresolved threads, ready to merge, linked session
waiting, no live session, stale. Reaches the workspace only through the host's
control socket (list-sessions, reveal-session, start-copilot-session,
resume-copilot-session); while the host is away, lanes keep its last known
sessions with unknown states. Must not
touch terminal behavior, the main window, or CopilotProjectsProtocol.

This is a scoped extension of the incumbent surface, not a new visual world.
`PRODUCT.md`, `DESIGN.md`, and `.impeccable/design.json` remain unchanged.
Implementation recorded on October 8, 2026. The native finish verdict cleared
its five requested fixes at the captured Mac/native-preview scope. That scoped
verdict is not whole-surface, hardware, or shipping approval.

## Direction contract

THESIS: Each goal is one lane read left to right across Draft, Checks, Review,
Ready, so a goal's progress and its blocker fit in one row. Refuses the flat
repo-sorted PR list and the notification inbox.

OWN-WORLD: Studio Console unchanged: chrome ground, sidebar-recessed goal column,
raised PR chips on the 6pt session corner, steel selection with 1pt edge, native
orange for needs-you and green for ready, system type, no new tokens.

STORY: Open on All, read how many PRs need you, optionally filter whole goals to
Needs you without losing quieter siblings, and inspect each PR's own blocker.
Go explicitly to the driving session or open the PR; when resuming an ended
session, see its identity, previous activity, and destination before acting.

FIRST VIEWPORT: 38pt drag strip; 56pt header with the all-PR needs-you count,
owners filter, and Refresh. A separate row carries All / Needs you, visible/total
goal count, GitHub freshness, and workspace status; refresh warnings sit below it.
The 32pt sidebar footer retains the window's keys and storage/settings warnings.
A sticky stage row heads four equal columns beside the unchanged 240pt goal
column: two-line goal, session/project context or previous-session identity and
activity, then Go to Session, Resume in <project>, or Start Session.
Session goals that need you lead.
Chips: repo#number with age, up to two title lines (omitted when the goal is named
after that pull request), PR-specific reason with a 1pt orange edge (green when
ready, quiet for nudges), and an explicit qualifier for partial status.
Non-draft chips in Checks also show a neutral eye and Ready for review after
their reason; Review and Ready omit this extra cue.
Signature: the most urgent chip is initially selected so Return
opens its session; refresh slides an advancing chip into its new stage (0.2s
ease-out); Reduce Motion changes lanes in place.

FORM: Goal Lanes, candidate 3 of 7 on the ordered list, surface seed 50c9b438.

FINISH: unreviewed and undocumented is unfinished; this build ends with the finish review, the verdict, DESIGN.md, and every shipping raster carrying its provenance

## Implemented surface behavior

**Review readiness without moving columns.** Non-draft chips in Checks show
Ready for review with the native eye symbol in secondary ink, after the blocker
or check status. Draft, Review, and Ready chips omit the extra cue. The label
means only that the PR is no longer a draft, not approval or merge readiness.
Tooltip text, keyboard announcements, and accessibility values put the action
reason first, then readiness. Triage, attention counts, goal sorting, and stage
assignment are unchanged. Companion views use the existing checks-stage field
for the same cue; no protocol change is required.

**Whole-goal filtering.** `PullRequestsFilter` defaults to All. Needs you retains
each goal whose `needsYouCount` is positive, including no-session/stale nudges,
and keeps every PR in that goal. It does not change triage, grouping, urgency, or
the header's all-fetched-PR counts. The status row reports visible/total goals;
stage counts follow visible lanes. The native segmented picker is 180pt wide
and disabled before the loaded phase. An empty filtered result says
"Nothing needs you" with Show All Goals only when status is complete. Otherwise
it repeats the header's "Checking PR status…" or "Some PR status is unknown"
with a question-mark icon, distinct from having no open PRs.

**Selection stays intentional.** `SelectionInputs` observes filter and visible
keys. A still-visible selection survives. If it disappears after a deliberate
filter change, the first visible key is selected; if it disappears on refresh,
selection clears rather than redirecting the next Return to a different PR.
Changing the filter returns focus to the lanes. Keyboard actions resolve only
against visible items: arrows move, Return goes to a connected session or GitHub,
Command-Return opens GitHub, and Escape clears selection. Double-click and the
existing chip context menu retain their destinations and manual goal assignment.
Arrow-key announcements and chip accessibility values share the same spoken
status, preserving every attention reason and any checking/unavailable qualifier.

**Session context once, when truthful.** The goal summary carries shared session
state. `sharesSessionState` compares every optional session ID, including nil.
Only when all agree and the summary has a session or sessions are known does
the chip omit `sessionWaiting` and `noSession` from its displayed reasons.
Mixed manual goals retain each item's session reasons. The chip edge, reason,
and +N reflect this displayed subset; a chip with no remaining reason uses its
assessment status. The original reasons still determine attention, ordering,
counts, tooltip content, keyboard announcements, and accessibility values.

**Resume names its destination.** A distinct, nongeneric candidate name appears
above "Previous session · <relative activity>". Names duplicating the goal
(case-insensitively after normalization) and "Copilot session" are omitted.
The primary menu label is "Resume in <project>", choosing the selected valid
project or the first available project. Its menu has Resume in and Start New
Session in sections listing projects. The label truncates within the existing
goal column; help and the accessibility label retain the full destination.
Resuming… disables repeat activation. Existing live goals use Go to Session;
known sessionless goals without a candidate use Start Session.

**Freshness is not connectivity.** The row independently shows Loading…,
Matching sessions…, or Refreshing… while busy, plus "GitHub checked <relative
time>" whenever a last-success timestamp exists. A later refresh failure keeps
the previous lanes and timestamp, with a readable warning below the row.
Connecting, unavailable, and incompatible-host messages describe Copilot
Projects separately. Disconnected last-known sessions keep their goals with
"Status unknown"; no snapshot says sessions were not matched, not that none
exist. Open Copilot Projects is offered only when the bundled host is openable.
The synthetic offline capture has no openable host and therefore no such button.

**Unknown is not ready or sessionless.** `sessionsKnown` requires a completed
match, a connected host, no match performed without live sessions, and no active
matching pass. An unmatched connected goal says Matching sessions… only during
an active pass, otherwise Sessions not matched (including after a failed rematch).
Start and Resume are withheld until matching and first-load status checking finish.
Ordinary refresh preserves known session actions/reasons; old PR links survive
until the enriched list replaces them. Initial unenriched PRs are incomplete,
not ready. Chips show Checking status… during initial enrichment and Some status
unavailable afterward for incomplete data, uncounted threads, or unknown required
check failures. The summary qualifies partial results instead of claiming
Nothing needs you when status is unknown and no known attention reason exists.

## Inherited visual rules

Studio Console's palette, native semantic type, geometry, depth, and motion are
unchanged. Callout semibold identifies the window; title3 semibold carries the
summary; body medium names goals; callout names PRs; caption/caption2 handle
context, reasons, identity, and age. The new row reuses caption secondary ink and
monospaced counts. Existing sidebar/raised/steel roles, native symbols, dividers,
and controls remain authoritative. These surface behaviors introduce no tokens
and do not turn Goal Lanes into an app-wide composition rule.

## Evidence and coverage boundary

- Source: `PullRequestsView.swift`, `PullRequestsPresentation.swift`, the
  matching/refresh/workspace phases in `PullRequestsModel.swift`, and shared
  `Sources/CopilotProjectsStyle/StudioStyle.swift`.
- `Tests/PullRequestsPresentationTests.swift` covers whole-goal filtering with
  quiet siblings/nudges, shared versus mixed session reasons, all-reason
  announcements with partial-status qualifiers, candidate-name suppression,
  active/inactive matching labels, partial status, and selection
  reconciliation. Its `PullRequestsDesignCaptureTests` also checks filtered
  empty states with complete/incomplete/uncounted status and ordinary
  refresh stability. `Tests/ResumableSessionsTests.swift` checks retention of
  old links through enrichment and first-load incomplete status, including
  the checking-status empty state, and a failed rematch after reconnecting.
- Native captures are outside the repository, under the session evidence root
  `~/.copilot/session-state/<session-id>/files/pr-design-evidence/`:
  `mac-dark.png`, `mac-light.png`, `mac-compact.png`, and `mac-offline.png`.
  `PullRequestsDesignCaptureTests.testCaptureNativeDesignStates` renders the
  actual SwiftUI/AppKit window at 1280x800pt or 880x800pt with `FakeWorkspace`,
  `model.show`, and no historical-session lookup. Sample PRs are
  `sample/workspace#14`, `sample/api#27`, `sample/agents#35`,
  `sample/automation#18`, and `sample/mobile#46`; the last is deliberately
  incomplete. The long project name, two live sessions, previous-session
  candidate, two-minute freshness, and offline failure are injected test data,
  not a live account, host, or GitHub observation.
- `mac-final-reviewed.log` records 101 selected tests, zero failures, and one
  skipped capture test when its environment variable was absent. The captures
  are separate evidence; a skipped renderer is not a rendered pass.
  `final-source-sha256.txt` records the source snapshot. No tests or captures
  were rerun for this documentation-only change.
- This is not end-to-end certification of live GitHub/host actions, keyboard
  focus, VoiceOver, high-contrast runtime, or every window size/state. The native
  finish verdict covers its five scored fixes, not those unobserved interactions.

Not canonized or repaired: the root DESIGN.md still describes earlier PR
freshness placement/labels, and the context loader does not recognize
PRODUCT.md's existing platform spelling. Both remain untouched under the
surface-only boundary; neither is a new system rule or a claim of final approval.

## Final review-readiness handoff — October 9, 2026

This dated addendum records the narrow indicator extension, not a redesign or a
replacement for the October 8 evidence above. Binding choices were
`ready_for_review` (no longer a draft, regardless of approval), `checks_only`, and
`all_clients` (Mac, iOS, and web/PWA). Operate remains the mode: expose review
availability during checks without moving PRs or giving it priority over blockers.

**Artifact and preserved system.** Source HEAD
`856f8ccec33d0b00a14c8bed8da24569a685b57b` was checked against
`pr-review-readiness-final-review/manifest.json` and its immutable `mac.patch`
(5 changed files; 155 patch lines; 9,605 bytes). The patch hash and complete
base-to-head diff match. Paths here are relative to the session evidence root
`~/.copilot/session-state/<session-id>/files/`.
Inspected `PullRequestsPresentation.reviewReadiness`, `PullRequestChip` rendering,
spoken status and tooltip, focused tests, and shared `StudioStyle.swift` against
the incumbent PRODUCT.md, DESIGN.md, and sidecar. The production diff is limited
to presentation and the view: triage, attention counts, grouping, sorting, stage
assignment, and actions are unchanged, with no API, protocol, pin, or token change.
Studio Console (`207346d7`) and Goal Lanes (`50c9b438`) remain authoritative;
no new comp, world, or shipping raster asset was introduced.

The helper requires both non-draft and Checks. Its native eye plus Ready for
review uses caption and existing secondary ink after the check/blocker reason.
Tooltip and spoken status preserve that ordering. Draft, Review, and Ready omit
it; an unknown stage is not a new readiness category. The same Checks-only
contract on companion clients omits unknown stages. This is informational,
neither an approval signal nor a new action or merge-ready treatment.

**Final evidence, separate from the older integration run.**

- `pr-review-readiness-mac-final.log` records 26 passing focused tests and zero
  failures. The helper matrix covers pending/expected/failing/error checks
  across review-required/approved/changes-requested/absent decisions; status
  tests cover blocker-first speech, running checks with empty reasons, and draft
  omission. These are focused assertions, not full UI branch coverage.
- Required native captures are
  `pr-review-readiness-final-captures/{mac-dark,mac-light,mac-compact,mac-offline}.png`.
  Dark/light are 2560×1600 pixels; compact/offline are 1760×1600 pixels.
  They use synthetic native fixtures, not production GitHub or live-host facts.
- The supplied final finish handoff reports **SHIP**, with no material fixes,
  for the full revised three-client indicator scope. All eight required captures
  across Mac, iOS, and web were valid and opened by the parent and reviewer.
  This is distinct from the older five-fix Mac verdict and is not whole-product
  certification, merge authorization, or release/deployment approval.

No tests, detector, or captures were rerun for this documentation handoff.
Native Swift has no detector evidence. Hardware, complete VoiceOver traversal,
high-contrast runtime, installed-PWA behavior, and live-host/GitHub actions remain
uncertified; the shared cross-client verdict does not expand those limits.
PRODUCT.md, DESIGN.md, and `.impeccable/design.json` remain unchanged.
Source, README, tests, pins, cache/auth behavior, and git index/HEAD are outside
this surface-only write; no commit, push, or merge is part of the handoff.

Not canonized or repaired by this addendum: the previously recorded freshness
and platform-context drift, and the context loader's stale-sidecar warning,
remain out of scope rather than becoming new visual rules.
