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
  session-strip:
    backgroundColor: "{colors.chrome}"
    height: "38px"
  session-selected:
    backgroundColor: "{colors.selection}"
    typography: "{typography.session}"
    rounded: "{rounded.session}"
    padding: "4px 10px"
  session-inactive:
    backgroundColor: "transparent"
    typography: "{typography.session}"
    rounded: "{rounded.session}"
    padding: "4px 10px"
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

Source: `Sources/CopilotProjectsHost/{StudioStyle.swift,Views.swift,TranscriptDrawer.swift}`.
The frontmatter expands seven app-owned color roles into four system appearances;
it is a record, not a shared runtime dependency. Portable size tokens express
SwiftUI points as CSS pixels for documentation previews. Semantic native type
sizes are deliberately not frozen into pixel values.

## Colors

### Primary

`selection` is the cool steel fill; `selection-edge` marks its boundary.
`message` quietly groups a user's transcript text without outlining a whole turn.

### Neutral

`chrome` frames the title, tabs, and drawer; `sidebar` recesses navigation;
`raised` gives inactive-tab hover a distinct surface. `secondary-text` is explicit
readable ink for fleet idle, footer version, and transcript labels/timestamps on
custom chrome. Primary text remains native `Color.primary`/label color, not a
new fixed color.

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

Use native system text styles: callout semibold for the project title, callout
medium for session titles, body medium for project rows, caption for row metadata,
caption semibold for transcript labels, caption2 for timestamps, and headline for
the drawer title. Fleet counts use the `status` token with monospaced digits.
Terminal fonts and ANSI rendering belong to the existing terminal renderer.

**The Native Type Rule.** Preserve system text semantics and full-strength inactive session titles; hierarchy comes from weight, spacing, and surface rather than dimming the whole tab.

## Layout

The title strip and session strip are separate equal-height rows. The title
leaves leading room for traffic lights (80pt); tabs stay outside the window-drag
region so their existing drag gesture reorders sessions. The native split
sidebar ranges from 200pt to 360pt, ideally 240pt, with a persisted divider.
Tabs scroll horizontally, cap at 210pt, and leave creation controls at the
trailing edge. The terminal stays continuously mounted.

The details drawer overlays the trailing side, with a 44pt heading row and
18pt horizontal transcript inset. It does not become a second primary workspace.

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
Selected tabs retain a one-point edge. Native List selection, status symbols,
capsules, window buttons, menus, and drag indicators keep their own geometry.

## Components

**Session tabs:** steel selected fill and edge; raised hover only when inactive.
Titles retain native primary ink. The end button remains a separate labeled
action, including in the accessibility representation.

**Project navigation and creation:** native sidebar List, persistent status line,
native context menus and drag/drop. Project names, session counts, and idle labels
share inherited List ink; there is no custom selected-row foreground switch.
New Project remains a borderless native button; session creation remains the
trailing split control.

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
- Don't dim inactive tab titles or merge high-contrast-light surface roles.
- Don't add glow, ornamental hardware, or selection scaling.
- Don't turn documentation tokens into a theme picker or a shared runtime dependency.
