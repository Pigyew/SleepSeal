---
version: alpha
name: SleepSeal
description: A native Mac sleep-control utility with a readable view of real power and connection state.
colors:
  primary: "#267A78"
  primaryDark: "#78CCC4"
  backgroundReference: "#F5F6F7"
  backgroundDarkReference: "#191D21"
  textReference: "#20262D"
  textDarkReference: "#EEF3F4"
typography:
  sans:
    fontFamily: "-apple-system, BlinkMacSystemFont, PingFang SC, sans-serif"
  mono:
    fontFamily: "SFMono-Regular, Menlo, monospace"
rounded:
  DEFAULT: "10px"
  compact: "8px"
spacing:
  pagePadding: "24px"
  sectionGap: "20px"
  sectionInset: "18px"
components:
  section:
    rounded: "10px"
    padding: "18px"
  navigation:
    width: "190px"
  window:
    width: "800px"
    height: "560px"
---

# SleepSeal design system

## Overview

SleepSeal is a native macOS utility for people investigating unusual battery drain during sleep. Its job is to make protection rules, actual device state, and persistent power settings understandable without Terminal. The visual reference is the Mac's own System Settings: readable labels, genuine system controls, and quiet, useful feedback.

The product register takes precedence over brand expression. The signature element is a four-corner display map that reports the user's real hot-corner configuration. It is functional evidence, not decoration. Avoid invented savings percentages, marketing hero layouts, a fake Windows hibernation timer, and terminal-styled control panels.

English and Simplified Chinese have equal status. The user can follow the system or choose either language. The audience is not restricted to a particular country. Japanese locale and Japan-specific business flows are outside this release.

`UI/Theme.swift` owns runtime colors and spacing; this file documents its intent and references. `SleepSealTheme.accent` uses the rounded RGB equivalents of the primary tokens. Background, surface, text, separators, focus, destructive actions, and accessibility contrast come from AppKit/SwiftUI semantic colors, rather than fixed reference swatches. All sections use `SealSection`, explanatory messages use `SealNote`, and all owned text comes from `Resources/{en,zh-Hans}.lproj/Localizable.strings` through `L10n`.

## Colors

Teal indicates the main action and selected protection state. It is not used as the sole carrier of meaning: icons and text identify ready, active, missing access, and errors. Native semantic surfaces follow light/dark and increased-contrast preferences. Reference swatches describe the intended atmosphere, not an alternative hard-coded surface system. Warnings use native orange plus a warning icon; inline validation uses native red and an explanatory sentence.

## Typography

Use the system San Francisco family and its platform Chinese fallback. Page titles use the native large-title style, section headings use headline, body uses the default body, supporting explanations use callout, and metadata uses caption. Only modifier symbols use system monospaced text. No downloaded fonts or startup font swaps. Allow Chinese and English help text to wrap; do not truncate recovery results or permission instructions.

## Layout

The window has a persistent sidebar and one vertical detail scroll owner. It starts at a comfortable desktop size and has a minimum of 800 × 560 points. Sidebar ideal width is 190 points; page padding is 24; section spacing is 20; section inset is 18. Detail content is capped at 900 points. Battery and adapter settings are vertically separate sections so the controls stay readable at the minimum width. Draft power inputs survive sidebar navigation.

## Elevation & Depth

Use flat native surfaces, a thin semantic separator, and no decorative shadow. Sheets and confirmation dialogs use platform modality and appearance. Feedback has a restrained tinted surface above the page body; the issue remains visible until dismissed or replaced by a later operation.

## Shapes

Sections have a 10-point radius; small notices and the display diagram use 8. Buttons, toggles, text fields, pickers, menus, focus indicators, scrollbars, and modal chrome retain native shapes and interaction. Never hide a scrollbar or replace a native control with a drawn imitation.

## Components

The canonical UI and lifecycle contract is [docs/UX_CONTRACT.md](docs/UX_CONTRACT.md).

Default, hover, pressed, keyboard focus, selected, disabled and busy behavior for controls belongs to SwiftUI/AppKit. Operations disable duplicate submission and show a progress indicator in the fixed header region. Read-only power modes explain the pending recovery, while timer fields remain available. Custom minute fields preserve invalid input with localized correction guidance.

Use a bordered-prominent button for the main action, native bordered buttons for secondary operations, and destructive intent only in the separate uninstall area and its final confirmation. Ordinary reversible saves do not need confirmation. Uninstall and restore-original-power actions name their consequence in native app-owned sheets or dialogs. Escape cancels. No arbitrary animation or pulsing shield is used; platform reduced-motion behavior is respected.

SF Symbols are the icon family. A symbol accompanies, rather than replaces, a state label. The display corner diagram and current-state readings provide combined VoiceOver labels. Toolbars retain accessible labels when a native layout displays only the icon.

Copy uses plain action verbs and explains the next step on failure. System blocker descriptions and exported backend details can retain macOS-provided names; application-owned headings, help, menus, errors and accessibility labels use the active app locale. No unmeasured battery or compatibility claims appear in the interface.

## Do's and Don'ts

- Do show the measured current connection and power state independently of the selected protection rules.
- Do keep the dashboard usable when the helper, service, or permission is missing.
- Do preserve drafts and recovery records across ordinary navigation and failed operations.
- Don't treat waking the display as permission to reconnect.
- Don't promise precise hibernation timing on Apple silicon.
- Don't auto-apply default idle timers on first open or silently overwrite external changes.
