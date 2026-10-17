# SleepSeal native UX contract

The approved SleepSeal 0.2 Beta product plan defines these workflows. Core policy and power transaction tests are authoritative for device changes. Views consume `DashboardModel`; `DashboardAction` is the sole UI-to-controller boundary. Mock models never call device adapters.

## Business context

| Concern | Source | UI consequence |
|---|---|---|
| Sleep recovery | `Sources/StateMachine.swift`, approved 0.2 plan | Display wakes do not restore; recovery failures retain a retry entry. |
| Trigger selection | Approved 0.2 plan, trigger policy implementation | All catches unknown events; custom leaves unknown events connected. SleepSeal's own sleep button is the precise manual entry. |
| Persistent power edits | Approved 0.2 plan, power settings transaction implementation | Read first, edit fields, explicitly apply; external-change conflicts require refresh. |
| Permissions and privilege | Approved 0.2 plan, narrow helper implementation | Missing access keeps the panel open and provides a repair action. No arbitrary command entry. |
| Privacy | Approved 0.2 plan | Export locally and explain that the user should review before sharing. No account, cloud sync or telemetry UI. |
| Uninstall lifecycle | Approved 0.2 plan | Restore transient sleep changes first; preserve failures; persistent timers restored only when explicitly selected. |

## Canonical UI Map

| Capability | Canonical owner | Source of truth | Allowed variants | Verification |
|---|---|---|---|---|
| Select/Listbox | SwiftUI `Picker` | Native macOS behavior + `UI/DashboardView.swift` | segmented/radio/native menu; popup geometry and keyboard owned by macOS | Build and keyboard/popup inspection |
| Form | `DashboardModel` drafts + `TimerField` | `UI/DashboardModel.swift` | editable minute fields, supported power modes, read-only recovery overlap | Model validation and power transaction tests |
| Scrollbar | Native SwiftUI `ScrollView` / sidebar `List` | macOS user accessibility and scroll preferences | one detail vertical scroll owner | Small-window inspection on each page |
| Toast | Shared `feedbackBanner` | `DashboardModel.feedbackKey/detail/isError` | success/error, persistent until dismissed | Mock success/error display inspection |
| Dialog | Native SwiftUI sheet / confirmation dialog | `DashboardView` uninstall and original-power restore | setup sheet, uninstall sheet, restore confirmation | Escape/cancel, title and action inspection |
| Navigation | Native `NavigationSplitView` and shared SwiftUI sidebar buttons | `DashboardPage` | five pages, Command-1 through Command-5, no nested independent navigation | Keyboard and page switching with drafts retained |

Native control ownership is intentional: operating-system popup geometry, focus, menu navigation, scrollers and VoiceOver behavior are accepted. A web table, date input, search, remote pagination, authentication, drag interaction and bulk selection are not applicable to this local utility.

## Workflow ledger

| Operation | Trigger | Pending | Success | Failure / recovery |
|---|---|---|---|---|
| Enable | Setup confirmation | Disable duplicate enable | Enable protection, close sheet, show state | Keep panel usable, show access repair |
| Rules | Save protection rules | Disable duplicate save | Save for next sleep; preserve active recovery | Keep draft and explain failure |
| Sleep | Sleep now, panel or menu | Wait for actual sleep confirmation | Protect only if confirmed and rule permits | Preserve connectivity when request fails |
| Persistent power | Apply changes | Freeze duplicate apply, preserve form | Verify actual settings and clear confirmed drafts | Keep values and inline error; conflict requires explicit refresh |
| Refresh draft conflict | Refresh and discard draft | Explicitly discard only this form's draft | Read current system values | Preserve readable last result and retry |
| Restore transient state | Restore connections | Busy, keep saved record | Restore original radios/mode and clear only confirmed recovery | Keep record, expose retry |
| Pause / quit | Explicit user action | Recover pending state first | Pause or quit after recovery | Keep app and recovery record available |
| Uninstall | Confirm uninstall sheet | Restore first | Remove only after successful recovery | Keep app/record for retry |
| Export | Export diagnostics | Native destination flow | Local report, success heading | Localized error and retry |

## Interaction and state

Onboarding preselects all methods and enables nothing before confirmation. “Set up later” closes the sheet; overview keeps an Enable protection button. Existing-user migration is handled by the controller and preserves All. Closing the dashboard leaves the menu bar owner running.

The overview separates measured radio/power states from policy. Unknown readings remain explicitly unknown, never assumed off. Last trigger and recovery keep independent result text. The panel and menu use consistent action labels through `L10n`.

Custom selection allows all 16 trigger combinations, including empty. Empty has an explanation. Hot-corner configuration is read-only; only actual display-sleep corners are selectable. The map includes all four actual corner actions and modifier symbols. Opening system settings never writes Dock preferences.

Power profiles load existing values without an initial write. Zero means Never; new nonzero minute edits accept integers 1–1440. Unusual original values remain visible and unchanged until edited. Battery and adapter drafts are independent. Mode edits are read-only while transient recovery is pending. Persistent timers and sleep snapshots have distinct controller stores.

Power draft state stays in the model across page changes. There is no destructive navigation prompt for a simple sidebar change because drafts remain available. A conflict banner supplies an explicit refresh/discard action. Invalid custom input remains editable with the localized correction message. macOS power assertions can defer sleep, and the blocker page explains this limitation without force-quit controls.

The blocker page offers an optional “Request blocking apps to quit before sleep” setting, off by default. Switching it on presents an app-owned native sheet before a configuration action is dispatched. Cancel is the default Return action, Escape cancels, and only the separately labeled Enable quit requests button opts in. The sheet explains that normal quit requests may end calls, stop downloads or interrupt work; save prompts are respected; system services are excluded; quit applications need to be reopened by the user; and the selected protection methods limit when requests apply. The interface never offers force quit. Switching the saved setting off dispatches immediately. The toggle follows persisted controller state, so a failed save does not appear enabled. A controller-provided cleanup summary is displayed separately from the active blocker list.

## Accessibility, localization and appearance

All owned labels, helper copy, menus, feedback headings and button text use English or Simplified Chinese resources selected by system/explicit language preference. Technical macOS assertion names and application names remain unmodified. System authorization is localized by macOS. Dates/times supplied by the controller use the selected locale.

Native controls own keyboard focus and VoiceOver semantics. The precise manual sleep action is an AppKit `NSButton` hosted in SwiftUI and exposes its localized label for an in-process accessibility press check. Sidebar buttons expose selection and provide Command-1 through Command-5 shortcuts; avoiding visual-effect list selection also keeps labels readable in owned-view screenshots. Icons without text have accessible labels. Sections have header traits; radio state and corner labels combine related text for reading. Sheets use native modal focus and Escape cancellation. The detail page scrolls at an 800 × 560 window, with no hidden scrollbars. Light/dark/increased contrast use native semantic surfaces. There is no custom animation requiring a separate reduced-motion path.

## Verification scope

Use `DashboardModel.mock` with a callback that changes only UI state. Exercise all five pages in both locales and appearances; small windows; custom form validation; custom trigger combinations; absent service/permissions; pending recovery; conflict and failure feedback; keyboard navigation and native popup open states. Rendering a view is evidence of layout only and must not be reported as a completed manual VoiceOver audit. The production controller remains responsible for validated XPC requests, helper authorization, durable recovery and safe migration.
