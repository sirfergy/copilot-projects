---
name: "Copilot Projects - Studio Console"
description: "Native macOS workspace with graphite and satin surfaces, steel selection, and a dominant live terminal."
colors:
  selection: "#3C4A56"
  selection-edge: "#AAC6D9"
  message: "#2D3943"
  chrome: "#202327"
  sidebar: "#25292E"
  raised: "#30363D"
  secondary-text: "#BAC4CE"
  selection-light: "#D4E0EB"
  selection-edge-light: "#365A76"
  message-light: "#E5EDF3"
  chrome-light: "#F0F2F4"
  sidebar-light: "#E4E8EC"
  raised-light: "#FFFFFF"
  secondary-text-light: "#526170"
  selection-high-light: "#CCDDE9"
  selection-edge-high-light: "#173B55"
  message-high-light: "#E2EAF0"
  chrome-high-light: "#FFFFFF"
  sidebar-high-light: "#DCE1E6"
  raised-high-light: "#EDF1F5"
  secondary-text-high-light: "#394958"
  selection-high-dark: "#374A59"
  selection-edge-high-dark: "#D5E9F6"
  message-high-dark: "#283742"
  chrome-high-dark: "#000000"
  sidebar-high-dark: "#16191D"
  raised-high-dark: "#24292F"
  secondary-text-high-dark: "#D5E0E9"
typography:
  title:
    fontFamily: "-apple-system, BlinkMacSystemFont, sans-serif"
    fontWeight: 600
  session:
    fontFamily: "-apple-system, BlinkMacSystemFont, sans-serif"
    fontWeight: 500
  label:
    fontFamily: "-apple-system, BlinkMacSystemFont, sans-serif"
    fontWeight: 600
  metadata:
    fontFamily: "-apple-system, BlinkMacSystemFont, sans-serif"
    fontWeight: 400
  status:
    fontFamily: "-apple-system, BlinkMacSystemFont, sans-serif"
    fontSize: "12px"
    fontWeight: 400
rounded:
  control: "5px"
  session: "6px"
  message: "9px"
spacing:
  tight: "4px"
  small: "6px"
  group: "8px"
  content: "10px"
  inset: "12px"
  section: "14px"
components:
  title-strip:
    backgroundColor: "{colors.chrome}"
    typography: "{typography.title}"
    height: "38px"
  project-rail:
    backgroundColor: "{colors.sidebar}"
    width: "176px"
  session-browser:
    backgroundColor: "{colors.chrome}"
    width: "224px"
  browser-header:
    backgroundColor: "{colors.chrome}"
    height: "56px"
  workspace-heading:
    backgroundColor: "{colors.raised}"
    height: "56px"
  session-selected:
    backgroundColor: "{colors.selection}"
    typography: "{typography.session}"
    rounded: "{rounded.session}"
    padding: "10px"
  session-inactive:
    backgroundColor: "transparent"
    typography: "{typography.session}"
    rounded: "{rounded.session}"
    padding: "10px"
  session-hover:
    backgroundColor: "{colors.raised}"
  project-row:
    padding: "5px 0"
  new-project:
    rounded: "{rounded.control}"
    padding: "4px 6px"
  user-message:
    backgroundColor: "{colors.message}"
    rounded: "{rounded.message}"
    padding: "10px"
  details-drawer:
    backgroundColor: "{colors.chrome}"
    width: "420px"
---

# Design System: Copilot Projects - Studio Console

## Overview

**Creative North Star: "Studio Console"**

A precise native workspace for parallel coding sessions. Graphite layers in dark
appearance and satin gray layers in light appearance frame the work without
competing with terminal output. Steel selection is steady and legible.

Native controls, readable system type, and compact spacing carry the character.
Details are available on demand; glow, ornamental hardware, and decorative
terminal motion are not part of the selected direction.

**Key Characteristics:**
- Adaptive native surfaces, not a user-selectable theme.
- Stable steel selection with readable inactive labels.
- Terminal-first work with secondary details.

Source: `Sources/CopilotProjectsHost/{StudioStyle.swift,Views.swift,AppEntry.swift,HostLifetime.swift,TranscriptDrawer.swift}`.
The frontmatter expands seven app-owned color roles into four system appearances;
it is a record, not a shared runtime dependency. Portable size tokens express
SwiftUI points as CSS pixels for documentation previews. Semantic native type
sizes are deliberately not frozen into pixel values.

## Colors

### Primary

`selection` is the cool steel fill; `selection-edge` marks its boundary.
`message` quietly groups a user's transcript text without outlining a whole turn.

### Neutral

`chrome` frames the title, session browser, and drawer; `sidebar` recesses the
project rail; `raised` distinguishes the active-session heading and inactive-row
hover. `secondary-text` is explicit readable ink for session states, project
context, fleet idle, footer version, and transcript labels/timestamps on custom
chrome. Primary text remains native `Color.primary`/label color, not a new fixed
color.

In system-owned project rows, the project name, session count, and idle label
have no explicit `foregroundStyle`. They inherit native List selection/emphasis
ink, including over an OS accent-selected row, rather than using fixed secondary
ink.

Unsuffixed tokens are dark appearance. The `-light`, `-high-light`, and
`-high-dark` families are the exact native appearance variants. Increased-contrast
light chrome, sidebar, and raised surfaces remain distinct. Native green,
orange, blue, purple, and indigo retain their existing status meanings; they
are not replaced by steel.

**The Readable Layers Rule.** Resolve all seven roles together from system appearance for custom chrome; keep their ink readable without overriding native List selection/emphasis colors on project names, session counts, or idle labels.

The native tests require text contrast of at least 4.5:1, selection-edge contrast
of at least 3:1, and raised-to-chrome/sidebar separation of at least 1.1:1.
These are palette checks, not a claim of complete visual or accessibility approval.

## Typography

Use native system text styles: callout semibold for the application title,
headline for browser headers, title3 semibold for the active-session heading,
body medium for project and session names, and caption for states and project
context. Session names wrap to two lines. Transcript labels use caption semibold,
timestamps use caption2, and the drawer title uses headline. Fleet counts use the
`status` token with monospaced digits. Terminal fonts and ANSI rendering belong
to the existing terminal renderer.

**The Native Type Rule.** Preserve system text semantics and full-strength inactive session titles; hierarchy comes from weight, spacing, and surface rather than dimming the whole row.

## Layout

The macOS [Two-Level Browser](.impeccable/surfaces/sources-copilotprojectshost-views-swift.md)
separates projects, sessions, and working content. The native top drag strip
(38pt) leaves leading room for traffic lights (80pt); navigation controls sit
below it. A resizable project rail (176pt minimum/default, 360pt maximum), Sessions column
(200pt minimum, 224pt ideal, 280pt maximum), and terminal/detail pane
(420pt minimum) share aligned headers (56pt). The Sessions divider persists
under `copilot-projects.sessions`; Projects uses `copilot-projects.projects`.
Drag either native divider to adjust the navigation widths. Session rows scroll vertically with a 6pt gap
and 10pt column inset. The main pane identifies the active session; its project
appears in the Sessions header rather than being repeated beneath the session title.
Its session-details opener sits beside the terminal glyph in that heading,
not over terminal output or in the native title strip. It appears only when
transcript or workflow details are available and the drawer is closed.

Projects can collapse immediately while Sessions remains visible. Visibility is
scene-owned ephemeral `@State`, passed as a `Binding` through `MainWindowContent`;
it is neither `AppModel` state nor a persisted preference. The native View menu's
Show Projects toggle (Command-0) and the resident session-header toggle share it.
Collapse preserves the terminal container, instance, and process. Focus leaves
the hidden project table for the visible terminal, or is cleared for an empty
project; an already-focused terminal is not blurred and refocused.

The root no-project and empty-session states remain. The unchanged details
drawer overlays the trailing side (420pt), with a 44pt heading row and 18pt
horizontal transcript inset. It does not become a second primary workspace.

**The Steady Selection Rule.** Change fill and edge without scaling or moving the selected session; retain separate select, end, and drag actions.

## Elevation & Depth

Tonal layers and native dividers do most of the work. The drawer alone has a
structural shadow (black at 20%, radius 12pt, x offset -4pt); modifier-number
badges retain their small existing shadow. This is not a blanket ban on native
shadows or borders.

Drawer disclosure uses an ease-out transition (0.18s); Reduce Motion disables
its custom animation and selects opacity instead of a slide. Existing
control-hover animation is ease-out (0.12s), disabled with Reduce Motion.

## Shapes

Use the recorded control, session, and message corners for their named purposes.
Selected session rows retain a one-point edge. Native List selection, status symbols,
capsules, window buttons, menus, and drag indicators keep their own geometry.

## Components

**Session browser:** vertically stacked, two-line names with explicit Running,
Waiting for input, Request failed, Finished, or Idle states. A failed latest
request shows a native red exclamation in the state slot (its help names the
CLI's message), and the transcript drawer marks that turn with a red **Failed**
capsule and a closing **Request failed** note. Selected rows use steel fill and
edge; raised hover applies only when inactive. Titles retain native primary ink.
Single-click selects; double-click on the selector ends that session through
the existing active-work confirmation. The dedicated End control and separate
accessibility buttons remain. Existing
project/session shortcuts, modifier-number hints, reordering, context actions,
and session-ending safeguards remain.

**Project navigation and creation:** native sidebar List with a stable compact
activity line. `ViewThatFits` shows activity symbols and counts when they fit,
otherwise the first active status in waiting/failed/running/background/scheduled
priority order. Sessions whose latest request failed count behind the session
row's red exclamation. Tooltips and accessibility labels retain all active counts;
project names have full-name tooltips. Names, counts, and idle labels inherit
List ink, with no custom selected-row foreground switch. Cross-project session
drop requires Projects to be shown. New Project remains a borderless native
button; session creation stays in the Sessions header's trailing split control.

**Transcript and details:** user text receives the message fill; assistant text
uses the drawer surface. Turns are separated rather than enclosed in nested
cards. Native Markdown selection, tool disclosure, and workflow controls remain.
Retained terminal images follow their associated turn, fit the drawer width
without changing aspect ratio, and cap inline height at 280pt. Loading reserves
the PNG's fitted geometry; unavailable images are labeled rather than hidden.
A prompt's images sit under the prompt. An image a tool returned sits under that
tool's row inside Tools, and the collapsed Tools header counts them.
Image corners reuse the 9pt message shape and native border treatment. Selecting
an image opens a larger native preview with pan/zoom and explicit dismissal.
The workspace UI input controller owns one preview item, shared by the root sheet
and command availability. It consumes preview dismissal before workspace or
terminal actions; this ownership does not depend on OS focus or focused values.
An open preview retains its captured image while the inline list responds to
eviction; changing session or closing the drawer dismisses the preview.

**Session finder:** Find Session… (Command-K, Session menu) is a 640x460pt sheet
on `chrome`: a 56pt search field (title3, magnifying glass in secondary ink), a
sectioned list, and a 32pt `sidebar` footer. Section headers (Recent Sessions,
Matches, Suggested by Luna) are caption semibold in secondary ink. Rows reuse the
session row's language: the existing state indicator, a one-line body-medium
title with a trailing caption relative time, and a caption context line
(project · folder · state · Current). The highlighted row takes steel fill, a
1pt edge, and the session corner; raised hover applies only when not highlighted.
A conversation match adds a one-line caption excerpt. Luna never moves a listed
row: a pick on a listed row adds an inline sparkle (selection-edge ink) to its
context line, with the reason in the tooltip and VoiceOver; extra picks append
below under Suggested by Luna with a one-line primary-ink reason. Focus stays in
the field while arrows and Return drive the list; Escape clears a search before
closing, and the footer legend says which. The footer's trailing note carries
Luna's status, with failures behind the native orange warning symbol. Reading
and waiting states are one secondary line under their section header; no-session
and no-result states use native `ContentUnavailableView`. While open, the sheet
owns workspace keys and workspace commands are disabled.

**Pull Requests window:** [Goal Lanes](.impeccable/surfaces/sources-copilotprojectshost-pullrequestsview-swift.md),
the one hidden-title-bar window (1200x760pt default, 880x480pt minimum) on
`chrome` of Copilot Pull Requests, a separate app nested in Copilot Projects so it
has its own Dock icon and Command-Tab entry. Window ▸ Pull Requests
(Shift-Command-P) or the menu bar item opens it or brings it forward; closing the
window quits it. It is the same Studio Console world, shared through the
`CopilotProjectsStyle` module, and being another process, workspace shortcuts and
terminal input never reach it. Its icon is the Copilot Projects teal squircle with
the white primer/octicons `git-pull-request-24` glyph (MIT) in place of the
mascot, drawn by `scripts/make-icon.swift --pull-requests` and built into
`Resources/PullRequestsIcon.icns` by `scripts/make-icns.sh`. It reuses the main
window's 38pt drag strip (80pt traffic-light inset, callout semibold title, the
system title-bar double-click action) and a 56pt header: a title3 semibold needs-you
headline over a caption secondary summary (open, goals, nudge-only count, owners),
then a trailing refresh note (spinner, "Updated" relative time, or a warning
behind the native orange symbol), the owners filter (a native token field in a
popover; the button names two owners, then a count), and Refresh
(Command-R). A sticky 28pt `chrome` stage row (caption semibold secondary, counts
in monospaced digits) heads a 240pt Goals column and four equal stage columns
(Draft, Checks, Review, Ready) split by native dividers; lanes are separated by
dividers. The goal column sits on `sidebar`: a two-line body-medium goal name, a
caption context line (the session state indicator with project · state, or "No
session on this goal" with a terminal symbol), a caption count, and a small
Go to Session button or Start Session split menu. Stage cells pad 8pt and stack
chips 6pt apart. Goals with an actionable pull request and a session lead, then
other actionable goals, then nudge-only and quiet goals, each by urgency.

Chips are `raised` on the 6pt session corner (10x8pt padding): a caption semibold
secondary `repo#number` with a trailing caption2 narrow age that drops before the
repository name truncates; up to two callout title lines, omitted when the goal is
named after that pull request; then a reason line. The inner 1pt status edge is
native orange (85%) when the chip needs you, green (70%) when ready to merge, and
a quiet secondary-ink edge (45%, 80% on hover) for no-session or stale nudges;
a chip with no reason shows that 80% edge only on hover. Hover adds no fill. Selection takes the steel fill and adds a 1pt `selection-edge`
ring drawn 2pt outside the chip on an 8pt corner (the session corner offset
outward, not a new radius), so the status edge stays visible inside it. The reason
line is the most urgent reason's symbol in the status tint, its label in primary
ink (secondary for nudges), and a "+N" for the rest; it falls back to a short
label, then drops "+N", and never truncates. A chip with no reason shows its review
status in secondary ink, up to two lines. Double-click opens the pull request; the
context menu opens, copies, goes to the session, or moves it to another goal.

The first load shows three redacted placeholder lanes under an unredacted stage
row; no pull requests and a first-load failure use native
`ContentUnavailableView`, the failure with Try Again. Later failures keep the
lanes and surface in the header's warning note. Sessions come from Copilot
Projects over its control socket. While it isn't answering, lanes keep its last
known sessions with their state shown as "Status unknown" and no indicator, the
goal column's button becomes Open Copilot Projects, and the footer's trailing note
says so in secondary ink; no-session nudges wait until sessions are known again.
A copy that couldn't lock its state folder and so saves nothing puts its warning
behind the native orange warning symbol in the same note. None of these states
uses `ContentUnavailableView`, which stays for having no data at all. The most urgent chip is
preselected and the lanes take focus: arrows move and announce, Return goes to the
chip's session (or GitHub when it has none), Command-Return opens GitHub, and
Escape clears selection. The footer is the session finder's 32pt `sidebar`
key-legend footer, listing only keys that can act now, with a trailing
older-pull-requests note. A refresh that moves a chip animates it to its new stage
(matched geometry, 0.2s ease-out); the first load never animates, and Reduce
Motion updates lanes in place.

**Notifications window:** [Reason Lanes](.impeccable/surfaces/sts-notifications-notificationsview-swift-d7a05b2b.md),
the one hidden-title-bar window (1200x760pt default, 880x480pt minimum) on
`chrome` of Copilot Notifications, a separate app nested in Copilot Projects
beside Copilot Pull Requests, with its own Dock icon, Dock badge, and Command-Tab
entry. Window ▸ Notifications (Shift-Command-N) opens it or brings it forward and
names the needs-you count in its title. The app's own menu bar item, a template
bell (bell.badge when something needs you) with the count in monospaced digits,
opens the window from its menu and can be turned off in the Banners popover. Closing the window does
not quit, so the badge and banners stay live, and the app menu's Start
Notifications with Copilot Projects toggle (on after the first open) launches it
windowless with `--background`. Its icon is the Copilot Projects teal squircle
with the white primer/octicons `bell-24` glyph (MIT) at the pull-request glyph's
size, drawn by `scripts/make-icon.swift --notifications` and built into
`Resources/NotificationsIcon.icns` by `scripts/make-icns.sh`. Needs you means
unread in To you, Via your teams, or Watching, except a review request whose pull
request is already merged or closed or whose open requests no longer reach the
user or a team they might be on, and a request, mention, or assignment the
user already answered (reviewed, commented, merged, or closed after they were last
asked); the Dock badge (none at zero, 999+ above 999), menu title, menu bar item,
header, bands, and lanes all count exactly that, within the window's scope. The
scope keeps threads from repositories in the chosen owners (empty means every
owner) and, by default, drops CI activity and activity on the user's own pull
requests (the Pull Requests window covers both; a mention or review request on one
still shows), draft pull requests (review requests on them included; a draft read for
an older copy shows until read again), and merged and closed pull requests and closed issues;
what's out of scope stays in the GitHub inbox (unless already answered, which
still clears it) but never shows, badges, banners, or counts here. A subject whose
state isn't known is never hidden for it, nor is one last read closed for an
older copy hidden or counted as settled (it may have been reopened; merged stays merged), and one read for
the first time waits for its state rather than showing and then vanishing. The primary copy marks answered
threads done on GitHub, and the filter row reports them as a caption
"Cleared N you'd answered" behind the checkmark.circle symbol, with the cleared
threads in its tooltip; a narrow row keeps only the symbol and N.

It reuses the Pull Requests window's drag strip and 56pt header: a title3 semibold
"N need you" headline ("Checking pull requests and issues…" while nothing needs you
and states are still being read) over a caption secondary summary (to you · via your teams ·
watching · already merged, closed, or withdrawn · quiet · accounts, monospaced digits),
the Pull Requests window's Owners button and token-field popover (its own list, kept
under `notifications.owners`, not shared with Pull Requests), a
Banners button (bell, or bell.slash when off) whose 300pt popover holds per-band
checkboxes and, when System Settings denies banners, a note behind the native
orange symbol with Open Notification Settings, then Refresh (Command-R). A caption
secondary filter row follows: an Unread | All segmented picker (opening on All,
disabled until loaded), a native bordered Hide pull-down button at the picker's
control size (eye.slash while anything is hidden, eye otherwise; what it hides, "Hiding CI,
your PRs, drafts, merged & closed" down to "Showing everything", is in its tooltip and
VoiceOver value rather than its title, which would grow with every filter) with checkmarks for CI Activity, Your Pull Requests, Draft Pull Requests, Merged Pull Requests, Closed Pull Requests, and Closed Issues
(each kept in `notifications.hides…`), "N of M threads" (M counts every
loaded thread; its tooltip names what's hidden and why), and trailing refresh progress, a "GitHub
checked" relative time that never wraps, or "Copilot Projects unavailable · sessions not linked".
Later refresh or sync failures keep the lanes and add one selectable caption line
under that row behind the outlined warning symbol in secondary ink. A sticky 28pt
`chrome` stage row heads a 240pt Reasons column and four equal freshness columns
(Since you looked, Today, This week, Older) split by native dividers, counts in
monospaced digits. Since you looked holds unread threads that changed after the
user last acted on them (opened, marked, unsubscribed, went to the session, or
copied the link; kept while nothing new happens on it) and after a baseline set once, on the
first refresh, from the last read on GitHub (if any); looking at the window moves nothing. The rest sit by day. Bands (To you, Via your teams, Watching,
Quiet) head their lanes in a 24pt `chrome` row: caption semibold name, then a
regular count of need-you and merged-or-closed threads (unread, for Quiet). The
lane column sits on `sidebar` (14x10pt inset): a two-line body-medium reason with
a borderless ellipsis menu (Mark All as Read, Mark All as Done), a caption
secondary explanation, and a caption count. Only non-empty bands and lanes appear;
chips lead unread, then newest. Cells pad 8pt, stack chips 6pt apart, and show
five before a borderless caption Show N more (then Show fewer).

Chips share Goal Lanes' `raised` body, 6pt session corner, 10x8pt padding,
fill-free hover, and steel selection with the 1pt `selection-edge` ring 2pt
outside on the 8pt corner. The identity line is a 6pt unread dot (orange when the
thread needs you, secondary ink otherwise, so unread is a shape and not only a
color), the subject kind's symbol and a caption semibold `repo#number` in
secondary ink, and a caption2 narrow age that drops before the repository name
truncates; then up to two callout title lines; a caption secondary detail line
(@team, Deployment approval, Draft/Merged/Closed, "Checking who was asked…", or
"as" a non-primary account); and, where a session works on the pull request, a
caption session line: its indicator and state, plus the project only when the
whole line fits, never cut short, and a click to that session while Copilot
Projects answers (otherwise a terminal glyph and "Status unknown"). The inner 1pt
edge is native orange (85%) for unread needs-you threads, secondary ink (45%, 80%
on hover) for unread quiet threads and unread review requests already merged, closed, or withdrawn,
and absent once read (80% on hover only). Double-click opens the thread on GitHub
and marks it read; the context menu opens, goes to the session, marks read or
done, unsubscribes, or copies the link.

The first load shows three redacted placeholder lanes under an unredacted stage
row, and keeps them whenever no lanes show while anything waits for its state; a first-load failure (Try Again; terminal symbol when gh is missing), an
empty inbox (Inbox Clear), an Unread filter with nothing unread (Show All), and
everything out of scope (All Threads Hidden, naming what's hidden, with Show Merged
& Closed and Show Every Owner as they apply)
use native `ContentUnavailableView`. The most urgent chip is preselected and the
lanes take focus: arrows walk band, lane, and column order through shown chips and
announce, Return goes to the session (or GitHub when there is none or the host is
away), Command-Return opens GitHub, E marks done and Shift-M unsubscribes (both
advancing selection), Shift-I marks read, and Escape clears selection. The footer
lists only keys that can act now; its trailing note carries the storage warning
and, when an account holds more unread than one read fetches, "Older unread
threads aren't shown · Open GitHub Inbox" as a native link. Done or Unsubscribe
removes a chip and ticks its counts down (matched geometry, 0.2s ease-out);
Reduce Motion updates in place. Banners announce only
unread needs-you threads in enabled bands that changed since the last
announcement, never the backlog and never while the window is key; more than
three at once become one summary banner.

**Shared patterns:** the 32pt `sidebar` key-legend footer (caption secondary ink,
semibold key glyphs, 14pt inset and spacing, trailing status note) is shared by
the session finder, the Pull Requests window, and the Notifications window. All
three put persistent failures (Luna's, or a copy that can't lock its state
folder) behind the native orange warning symbol in that trailing note and use
`ContentUnavailableView` for empty states. The two lane windows also share the
drag strip, 56pt header, `raised` chip body, selection ring, and redacted
first-load lanes, and both start their filter row's native segmented picker, at
its natural width, on the 14pt leading edge the headline and columns share.

The [sidecar](.impeccable/design.json) contains schematic dark-appearance HTML/CSS
previews of these roles, not replacements for native controls or pixel-certified
renders. Its generated tonal ramps are swatch previews, not additional app tokens.

## Do's and Don'ts

### Do:
- Do resolve the complete native appearance family for custom chrome, while leaving native List row ink inherited.
- Do retain native labels, traffic lights, keyboard shortcuts, drag/drop, and ending safeguards.
- Do keep the terminal primary and the details drawer secondary.

### Don't:
- Don't dim inactive session titles or merge high-contrast-light surface roles.
- Don't add glow, ornamental hardware, or selection scaling.
- Don't turn documentation tokens into a theme picker or a shared runtime dependency.
