---
version: 1
slug: "sts-notifications-notificationsview-swift-d7a05b2b"
primary_target: "Sources/CopilotProjectsPullRequests/Notifications/NotificationsView.swift"
related_targets: ["Sources/CopilotProjectsPullRequests/Notifications/NotificationsModel.swift","Sources/CopilotProjectsPullRequests/Notifications/NotificationsService.swift","Sources/CopilotProjectsPullRequests/Notifications/NotificationsApplication.swift","Sources/CopilotProjectsHost/NotificationsAppLauncher.swift","Sources/CopilotProjectsStyle/StudioStyle.swift","Tests/NotificationsTests.swift"]
---

# Notifications: Reason Lanes

Mode: Operate. The one window of Copilot Notifications, a separate macOS app
nested in Copilot Projects beside Copilot Pull Requests, with its own Dock icon,
Dock badge, and ⌘Tab entry. Unlike Pull Requests it keeps running after its
window closes so the badge and banners stay live. It mirrors the GitHub
notifications inbox of every account signed in to gh, splits what reached the
user directly from what reached a team, and syncs Open (read) and Done back to
GitHub. PR threads a live Copilot session works on offer Go to Session.

Audience: one person drowning in volume (the measured account has ~4,900 unread,
~450/day, 72% CI). Job: see what needs me now, act or clear it, trust the badge.
Needs you: review requests, mentions, assignments, activity on my work,
conversations I'm in, and watched threads. CI and other system mail stay quiet:
listed, never badged or bannered.

## Direction contract

THESIS: Each reason is a lane read left to right by freshness, so what is piling
up, and whether it is yours or a team's, shows in one glance. Refuses the flat
repo-sorted inbox and the one-at-a-time triage deck.

OWN-WORLD: Studio Console unchanged, sibling to Goal Lanes: chrome ground,
sidebar-recessed 240pt reason column, raised thread chips on the 6pt session
corner, steel selection with a 1pt edge ring 2pt outside, native orange 1pt edge
for unread needs-you, quiet secondary edge for unread CI and unread review
requests already merged or closed; read chips are edgeless until hovered, like
Goal Lanes' chips with no reason. System type, no new tokens.

STORY: Open on All, read how many unread threads need you split To you / Via
your teams / Watching, scan the To you band first, open or clear each chip, bulk
clear a team lane, and leave knowing the badge counts only what still needs you.

FIRST VIEWPORT: 38pt drag strip; 56pt header with "N need you" (title3
semibold) over "to you · via teams · watching · accounts" (caption), Alerts menu
and Refresh. Filter row: Unread / All segmented, visible/total threads, GitHub
freshness. Sticky 28pt stage row: Reasons | Since you looked | Today | This week
| Older with counts. Bands To you, Via your teams, Watching, Quiet each head
their lanes; the lane column names the reason, its unread count, and a lane
menu (Mark All Read, Mark All Done). Chips: type glyph, repo#number, age; up to
two callout title lines; a detail line with team, PR state, account, or the
linked session. Footer: 32pt key legend (↑↓, ↩, ⌘↩, E Done, ⇧I Read, ⌘R) with
a trailing coverage note. Signature: when you come back, chips you already saw
slide out of Since you looked into their day column (0.2s ease-out matched
geometry); Done collapses a chip and ticks its counts down; Reduce Motion
updates in place.

FORM: Reason Lanes, candidate 4 of 7 on the ordered list, surface seed f1aa332e.

FINISH: unreviewed and undocumented is unfinished; this build ends with the finish review, the verdict, DESIGN.md, and every shipping raster carrying its provenance

## Unresolved

- Mac only, by the user's choice.
- Team mentions do not name the team (the API does not say which).

## Evidence and coverage boundary

- Source: `Notifications/NotificationsView.swift` (window, header, filter row,
  bands, lanes, chips, footer, states); `GitHubNotifications.swift` (reasons to
  lanes and bands, freshness columns, review requests settled as merged or closed, and
  `NotificationCounts` with the badge label); `NotificationsModel.swift` (looks,
  banners, badge, summary); `NotificationsApplication.swift` (the AppKit window
  that survives close, Dock badge, banners, `--background`);
  `Sources/CopilotProjectsHost/NotificationsAppLauncher.swift` and `AppEntry.swift`
  (Window ▸ Notifications ⇧⌘N with its count, Start Notifications with Copilot
  Projects); the menu bar bell and count belong to `NotificationsApplication.swift`; shared `Sources/CopilotProjectsStyle/StudioStyle.swift`.
- Shipping raster: `Resources/NotificationsIcon.icns`, rendered by
  `scripts/make-icon.swift --notifications` from primer/octicons `bell-24` (MIT,
  path data and license named in the script) on the existing teal squircle, and
  built by `scripts/make-icns.sh`. No other raster asset was introduced.
- `Tests/NotificationsTests.swift` covers decoding and paging, subject URLs, a
  lane and band for every reason, review requests staying yours until history
  shows only a team, freshness from the last look, band order with unread first,
  refresh counts, first-load failure versus later warnings, open/read/done and a
  failed Done, columns catching up with the last look, the first look seeded
  from GitHub's last read, banners and the summary banner, and session links.
  These are focused assertions, not full UI branch coverage.
- Native captures are outside the repository, under the session evidence root
  `~/.copilot/session-state/<session-id>/files/notifications-captures/`:
  `mac-dark.png` and `mac-light.png` (1280x800pt, 2560×1600 pixels), and
  `mac-compact.png` (dark) and `mac-offline.png` (light) (880x800pt, 1760×1600
  pixels). `NotificationsDesignCaptureTests.testCaptureNativeDesignStates`
  renders the actual SwiftUI/AppKit view with `FakeWorkspace` and `model.show`.
  Threads are synthetic `sample/*` fixtures across all four bands for `octocat`
  and `hubot`, with a one-hour-old look, a one-minute-old GitHub check, and one
  linked waiting session; offline adds an unreachable host, a refresh warning,
  and a truncated account. They are injected test data, not live GitHub or host
  observations.
- Live: the built helper read a real two-account inbox. That run observed the
  accessibility tree only; no images were captured from it.
- Finish review: the first pass returned fix with five material fixes (counts
  matching the badge, a session line that never truncates to a fragment,
  contract/render agreement on read chips, the filter row on the 14pt edge in
  both Notifications and Pull Requests, ⇧M in the footer). A fresh verdict pass
  scored all five resolved and returned ship, scoped to those fixes.
- No tests or captures were rerun for this documentation. This is not
  certification of the whole surface, hardware, VoiceOver traversal,
  high-contrast runtime, live banner delivery, or live GitHub/host actions.

Build over contract, recorded rather than reverted: FIRST VIEWPORT's alerts
control shipped as a Banners button with a per-band popover; the footer adds ⇧M
Unsubscribe and labels ⇧I Mark Read; cells show five chips before Show N more;
and the host-unavailable note and later failures sit in and under the filter row,
as in the Pull Requests build. The contract blocks above are unchanged.

Scope refinement (user-requested filters, option A chosen by the user): the header
gains the Pull Requests window's Owners button and token-field popover, with its own
list (`notifications.owners`), before Banners; the filter row gains a native
pull-down after Unread | All, first labeled by what it hides and later, at the user's
request, a bordered Hide button (eye.slash / eye) with that list in its tooltip, with checkmarks for CI Activity and Your Pull Requests (added later at
the user's request: the Pull Requests window covers both), Draft Pull Requests (also added
at the user's request), Merged Pull Requests, Closed Pull Requests,
and Closed Issues. Out-of-scope threads leave the lanes, header, badge, banners, and
summary; "N of M threads" counts every loaded thread and its tooltip names what's
hidden. A subject read for the first time, or last read closed for an older copy,
waits for its state (placeholder lanes if nothing else is left); an unknown state,
or a closed one read for an older copy, is never hidden. Answered threads are still
cleared on GitHub when hidden (the user's choice). All Threads Hidden joins
the `ContentUnavailableView` states. At 880pt the cleared note drops to its symbol
and count and "GitHub checked" never wraps. Evidence: `NotificationsTests` scope,
owner, label, badge/banner/persistence, and first-read tests; native captures (now
including `mac-all-hidden.png`, and `mac-dark.png` with owners set) rerun under the
session evidence root in `notifications-captures-filters/`. These are synthetic
renders; the open pull-down and the Owners popover were not captured.

Not canonized or repaired: the root DESIGN.md Pull Requests paragraph still
places refresh status and warnings in the header and the host-unavailable note
in the footer, and omits its filter row; `.impeccable/design.json` predates both
lane windows. Both remain untouched under this boundary.
