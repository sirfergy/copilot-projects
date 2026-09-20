# Copilot Projects

<!-- impeccable:product-schema 1 -->

## Platform

Native macOS.

## Stack

SwiftUI and AppKit, with the existing SwiftTerm terminal renderer. The public
desktop host and shared packages remain separate from the remote integration
and native iOS client.

## Users

People managing parallel persistent coding-agent sessions, grouped by project,
and returning to those sessions throughout the working day.

## Product Purpose

Keep work organized, make attention states understandable, and return quickly
to the right live session.

## Operating Context

The Mac workspace leads the suite. The live terminal is primary; completed
turns and session details live in a secondary drawer. Project navigation,
session navigation, native window controls, and keyboard speed remain central.
The user approved replacing horizontal tabs with a Two-Level Browser: separate
project and session columns, with the project column collapsible.
Web and iOS adapt this language rather than reproducing Mac chrome; their
existing conversation-first defaults remain intentional.

## Capabilities and Constraints

Preserve persistent terminals, project/session identity, keyboard shortcuts,
drag/drop, native labels, attention states, details access, and session-ending
safeguards. Studio Console changes visual hierarchy, not terminal behavior,
message delivery, control leases, queues, or shared package contracts.

## Brand Commitments

Keep the Copilot Projects identity and native platform conventions. The user
selected Studio Console, grounded candidate 1 from seed `207346d7`, and
authorized implementation. This was code-led, with no approved pixel comp or
generated imagery. The approved language is layered graphite in dark appearance,
satin gray in light appearance, steel selection, readable system type, and
restrained attention colors, without glow or ornamental hardware.

## Evidence on Hand

The current `StudioStyle.swift`, `Views.swift`, and `TranscriptDrawer.swift` in
`Sources/CopilotProjectsHost/` define the recorded implementation. Native
contrast tests cover the palette roles. This record is source-grounded, not
complete macOS full-window visual certification; VoiceOver and hardware
interaction are not certified by the companion rendered finish review.

## Product Principles

- Keep the live terminal dominant and details available on demand.
- Make selection and actionable status legible without moving the workspace.
- Preserve expert speed and native controls.
- Adapt companions to their platform and established workflows.

## Accessibility & Inclusion

Respect system appearance and increased contrast, retain readable primary and
secondary text, accessible selection/status labels, distinct select/end actions,
keyboard navigation, and Reduce Motion behavior. See [DESIGN.md](DESIGN.md) for
the extracted tokens and the [surface contract](.impeccable/surfaces/sources-copilotprojectshost-views-swift.md)
for this workspace's composition.
