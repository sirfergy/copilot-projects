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
and 10pt column inset. The main pane identifies the active session and its project.
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
Waiting for input, Finished, or Idle states. Selected rows use steel fill and
edge; raised hover applies only when inactive. Titles retain native primary ink.
Single-click selects; double-click on the selector ends that session through
the existing active-work confirmation. The dedicated End control and separate
accessibility buttons remain. Existing
project/session shortcuts, modifier-number hints, reordering, context actions,
and session-ending safeguards remain.

**Project navigation and creation:** native sidebar List with a stable compact
activity line. `ViewThatFits` shows activity symbols and counts when they fit,
otherwise the first active status in waiting/running/background/scheduled
priority order. Tooltips and accessibility labels retain all active counts;
project names have full-name tooltips. Names, counts, and idle labels inherit
List ink, with no custom selected-row foreground switch. Cross-project session
drop requires Projects to be shown. New Project remains a borderless native
button; session creation stays in the Sessions header's trailing split control.

**Transcript and details:** user text receives the message fill; assistant text
uses the drawer surface. Turns are separated rather than enclosed in nested
cards. Native Markdown selection, tool disclosure, and workflow controls remain.

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
