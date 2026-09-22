---
version: 1
slug: "sources-copilotprojectshost-views-swift"
primary_target: "Sources/CopilotProjectsHost/Views.swift"
related_targets: ["Sources/CopilotProjectsHost/HostLifetime.swift","Sources/CopilotProjectsHost/AppEntry.swift","Sources/CopilotProjectsHost/TranscriptDrawer.swift","Sources/CopilotProjectsHost/TranscriptImageView.swift"]
---

# Two-Level Browser

Mode: Operate. The user explicitly approved navigation changes and selected
the two-column project/session browser. Preserve terminal behavior, existing
shortcuts and session actions, drag/reorder, identity, and ending safeguards.

## Direction contract

THESIS: Make project, session, and working content distinct levels. Replace the
horizontal session strip, rather than merely repainting the existing layout.

OWN-WORLD: Inherit Studio Console's graphite/satin surfaces, steel selection,
readable ink, system typography, and native controls. No new visual identity.

STORY: Select a project, scan its session names and explicit states, then work
in the selected terminal. Hide Projects when the task needs more room.

FIRST VIEWPORT: Keep the 38-point native title strip. Below it, a compact
project rail and a vertically scrolling session column sit beside the terminal.
Aligned column headers establish hierarchy; an active-session heading replaces
the old tabs. The terminal remains at least half the window width at supported
capture sizes. The signature interaction collapses only the project column,
reclaiming width without remounting or restarting the terminal.

The session-details opener sits beside the decorative terminal glyph in the
active-session heading, not in the native title strip or over terminal output.
The user explicitly chose this placement. Retain the existing availability and
per-session open state; the drawer and its close action remain unchanged.
The current-session heading contains its title and controls only; retain project
context in the Sessions header instead of repeating it below the active title.

The drawer also renders host-associated retained terminal images below their
turns. Keep intrinsic aspect ratio and a bounded inline height, reserve loading
geometry, and make a larger native preview available without forwarding its
keyboard input to the terminal. Reuse the host's session/version image identity
and retention rules; do not fetch arbitrary Markdown URLs or paths.

FORM: Two-Level Browser, grounded structural candidate 5, chosen by the user
from the three structures dealt by surface seed 2bd5ac36. The established visual
world remains Studio Console (direction seed 207346d7). Code-led, no pixel comp.

FINISH: unreviewed and undocumented is unfinished; this build ends with the finish review, the verdict, DESIGN.md, and every shipping raster carrying its provenance
