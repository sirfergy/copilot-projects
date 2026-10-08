---
version: 1
slug: "sources-copilotprojectshost-pullrequestsview-swift"
primary_target: "Sources/CopilotProjectsPullRequests/PullRequestsView.swift"
related_targets: ["Sources/CopilotProjectsPullRequests/PullRequests.swift","Sources/CopilotProjectsPullRequests/PullRequestsModel.swift","Sources/CopilotProjectsPullRequests/PullRequestsWorkspace.swift","Sources/CopilotProjectsPullRequests/PullRequestsApplication.swift","Sources/CopilotProjectsHost/PullRequestsAppLauncher.swift","Sources/CopilotProjectsStyle/StudioStyle.swift"]
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

## Direction contract

THESIS: Each goal is one lane read left to right across Draft, Checks, Review,
Ready, so a goal's progress and its blocker fit in one row. Refuses the flat
repo-sorted PR list and the notification inbox.

OWN-WORLD: Studio Console unchanged: chrome ground, sidebar-recessed goal column,
raised PR chips on the 6pt session corner, steel selection with 1pt edge, native
orange for needs-you and green for ready, system type, no new tokens.

STORY: Open the window, read how many PRs need you, scan lanes ordered by urgency,
see each needs-you chip's reason, jump straight to the driving session or the PR,
and resume the ended session that worked on a goal, or start one, where it has none.

FIRST VIEWPORT: 38pt drag strip; 56pt header with needs-you count, last refresh,
owners filter, refresh; 32pt sidebar footer with the window's keys. Sticky stage
row over four equal columns beside a 240pt goal column (two-line goal, session
state and project or "Previous session · <when>", Go to Session, Resume Session
with Start New Session in its menu, or Start Session). Session goals that need you lead.
Chips: repo#number with age, up to two title lines (omitted when the goal is named
after that pull request), reason line with a 1pt orange edge (green when ready,
quiet edge for nudges). Signature: the most urgent chip is preselected so Return
opens its session; refresh slides an advancing chip into its new stage (0.2s
ease-out); Reduce Motion changes lanes in place.

FORM: Goal Lanes, candidate 3 of 7 on the ordered list, surface seed 50c9b438.

FINISH: unreviewed and undocumented is unfinished; this build ends with the finish review, the verdict, DESIGN.md, and every shipping raster carrying its provenance
