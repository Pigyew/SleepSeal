import AppKit
import SwiftUI

struct DashboardView: View {
    @ObservedObject var model: DashboardModel
    @State private var confirmUninstall = false
    @State private var confirmPowerRestore = false
    @State private var restorePowerOnUninstall = false

    var body: some View {
        NavigationSplitView {
            VStack(alignment: .leading, spacing: 0) {
                HStack(spacing: 9) {
                    Image(systemName: "moon.circle.fill").font(.system(size: 27)).foregroundStyle(SleepSealTheme.accent)
                    Text("SleepSeal").font(.headline)
                }.padding(18)
                VStack(spacing: 3) {
                    ForEach(Array(DashboardPage.allCases.enumerated()), id: \.element.id) { index, page in
                        Button { model.page = page } label: {
                            Label(model.text("page.\(page.rawValue)"), systemImage: page.symbol)
                                .font(.body)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(.horizontal, 12).padding(.vertical, 10)
                                .foregroundStyle(model.page == page ? SleepSealTheme.accent : Color.primary)
                                .background(model.page == page ? SleepSealTheme.accent.opacity(0.14) : Color.clear, in: RoundedRectangle(cornerRadius: 7))
                        }
                        .buttonStyle(.plain)
                        .keyboardShortcut(KeyEquivalent(Character(String(index + 1))), modifiers: .command)
                        .accessibilityAddTraits(model.page == page ? .isSelected : [])
                    }
                }.padding(.horizontal, 10)
                Spacer(minLength: 12)
                Text(model.appVersion).font(.caption).foregroundStyle(.secondary).padding(18)
            }
            .navigationSplitViewColumnWidth(min: 175, ideal: 190, max: 220)
        } detail: {
            ScrollView {
                VStack(alignment: .leading, spacing: SleepSealTheme.sectionSpacing) {
                    header
                    if let feedback = model.feedbackKey { feedbackBanner(feedback) }
                    if !model.serviceAvailable {
                        SealSection(model.text("guard.unavailable")) {
                            SealNote(text: model.text("service.unavailable"), symbol: "exclamationmark.triangle")
                            Button(model.text("action.repair")) { model.send(.repairInstallation) }.disabled(model.isBusy)
                        }
                    }
                    pageContent
                }
                .padding(SleepSealTheme.pagePadding)
                .frame(maxWidth: 900, alignment: .leading)
                .frame(maxWidth: .infinity, alignment: .topLeading)
            }
            .background(SleepSealTheme.background)
            .toolbar {
                ToolbarItem {
                    Button { model.send(.refresh) } label: {
                        Label(model.text("action.refresh"), systemImage: "arrow.clockwise")
                    }.help(model.text("action.refresh")).disabled(model.isBusy)
                }
            }
        }
        .frame(minWidth: 800, minHeight: 560)
        .tint(SleepSealTheme.accent)
        .environment(\.locale, Locale(identifier: model.language.localeIdentifier))
        .sheet(isPresented: $model.onboardingRequired) { onboarding }
        .sheet(isPresented: $confirmUninstall) { uninstallSheet }
        .confirmationDialog(model.text("power.restore.title"), isPresented: $confirmPowerRestore, titleVisibility: .visible) {
            Button(model.text("action.confirmRestorePower")) { model.send(.restorePower) }
            Button(model.text("action.cancel"), role: .cancel) {}
        } message: { Text(model.text("power.restore.message")) }
    }

    private var header: some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 6) {
                Text(model.text("page.\(model.page.rawValue)"))
                    .font(.system(.largeTitle, design: .default).weight(.semibold))
                    .accessibilityAddTraits(.isHeader)
                Text(model.text(pageIntro)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 10)
            if model.isBusy {
                ProgressView().controlSize(.small).accessibilityLabel(model.text("state.unknown"))
            }
        }
    }
    private var pageIntro: String {
        switch model.page {
        case .overview: return "app.tagline"
        case .protection: return "protection.intro"
        case .power: return "power.intro"
        case .diagnostics: return "diagnostics.intro"
        case .settings: return "settings.language.help"
        }
    }
    @ViewBuilder private var pageContent: some View {
        switch model.page {
        case .overview: overview
        case .protection: protection
        case .power: power
        case .diagnostics: diagnostics
        case .settings: settings
        }
    }
    private func feedbackBanner(_ key: String) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: model.feedbackIsError ? "exclamationmark.triangle.fill" : "checkmark.circle.fill")
                .foregroundStyle(model.feedbackIsError ? Color.orange : SleepSealTheme.accent)
            VStack(alignment: .leading, spacing: 4) {
                Text(model.text(key)).font(.callout.weight(.medium))
                if !model.feedbackDetail.isEmpty { Text(model.feedbackDetail).font(.caption).textSelection(.enabled) }
            }
            Spacer(minLength: 4)
            Button { model.feedbackKey = nil; model.feedbackDetail = "" } label: {
                Image(systemName: "xmark")
            }.buttonStyle(.borderless).accessibilityLabel(model.text("action.dismiss"))
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background((model.feedbackIsError ? Color.orange : SleepSealTheme.accent).opacity(0.10), in: RoundedRectangle(cornerRadius: 8))
        .accessibilityElement(children: .contain)
    }

    private var overview: some View {
        VStack(spacing: SleepSealTheme.sectionSpacing) {
            SealSection(model.text(model.statusKey), subtitle: model.text(model.detailKey)) {
                HStack(spacing: 12) {
                    Image(systemName: model.guardPending ? "shield.fill" : "shield.lefthalf.filled")
                        .font(.system(size: 32)).foregroundStyle(SleepSealTheme.accent).accessibilityHidden(true)
                    Text(model.text(model.guardPending ? "diagnostics.pending" : "overview.actual.help"))
                        .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
                if !model.isEnabled {
                    Button(model.text("action.enable")) { model.onboardingRequired = true }
                        .buttonStyle(.borderedProminent).disabled(model.isBusy)
                }
            }
            SealSection(model.text("overview.actual")) {
                HStack(spacing: 0) {
                    stateReading("device.wifi", symbol: "wifi", state: model.wifi)
                    Divider().frame(height: 48)
                    stateReading("device.bluetooth", symbol: "antenna.radiowaves.left.and.right", state: model.bluetooth)
                    Divider().frame(height: 48)
                    stateReading("device.lowPower", symbol: "battery.25percent", state: model.lowPower)
                }
            }
            SealSection(model.text("overview.actions"), subtitle: model.text("overview.actions.help")) {
                HStack(spacing: 12) {
                    NativeSleepButton(title: model.text("action.sleep"), enabled: model.canUseActions) { model.send(.sleepNow) }
                    Button { model.send(.displayOff) } label: { Label(model.text("action.displayOff"), systemImage: "display") }
                        .disabled(!model.canUseActions)
                }
            }
            SealSection(model.text("overview.events")) {
                eventRow("overview.trigger", value: model.lastTriggerKey, detail: model.lastTriggerDetail)
                Divider()
                eventRow("overview.recovery", value: model.lastRecoveryKey, detail: model.lastRecoveryDetail)
            }
        }
    }
    private func stateReading(_ title: String, symbol: String, state: UIActualState) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Label(model.text(title), systemImage: symbol).font(.callout).foregroundStyle(.secondary)
            Text(model.text(state.key)).font(.title3.weight(.medium))
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 8)
        .accessibilityElement(children: .combine)
    }
    private func eventRow(_ title: String, value: String, detail: String) -> some View {
        HStack(alignment: .top) {
            Text(model.text(title)).foregroundStyle(.secondary).frame(width: 140, alignment: .leading)
            VStack(alignment: .leading, spacing: 4) {
                Text(model.text(value))
                if !detail.isEmpty { Text(detail).font(.caption).foregroundStyle(.secondary).textSelection(.enabled) }
            }
            Spacer(minLength: 0)
        }.accessibilityElement(children: .combine)
    }

    private var protection: some View {
        VStack(spacing: SleepSealTheme.sectionSpacing) {
            SealSection(model.text("protection.title")) {
                Picker(model.text("protection.title"), selection: $model.policy.allSources) {
                    Text(model.text("policy.all")).tag(true)
                    Text(model.text("policy.custom")).tag(false)
                }.pickerStyle(.radioGroup).labelsHidden()
                SealNote(text: model.text(model.policy.allSources ? "policy.all.help" : "policy.custom.help"))
                if !model.policy.allSources {
                    Divider()
                    ForEach(UITrigger.allCases) { trigger in
                        Toggle(isOn: triggerBinding(trigger)) {
                            Label(model.text("trigger.\(trigger.rawValue)"), systemImage: trigger.symbol).font(.body.weight(.medium))
                        }
                        Text(model.text("trigger.\(trigger.rawValue).help")).font(.callout).foregroundStyle(.secondary).padding(.leading, 20)
                    }
                    if model.policy.sources.isEmpty {
                        SealNote(text: model.text("policy.none"), symbol: "exclamationmark.triangle")
                    }
                }
                HStack {
                    Spacer()
                    Button(model.text("action.save")) { model.send(.savePolicy(model.policy)) }
                        .buttonStyle(.borderedProminent).disabled(!model.policyDirty || model.isBusy)
                }
            }
            SealSection(model.text("corners.title"), subtitle: model.text("corners.help")) {
                CornerMap(model: model)
                if !model.corners.contains(where: \.isSleep) { SealNote(text: model.text("corners.none")) }
                if !model.policy.allSources && model.policy.sources.contains(.hotCorner) {
                    Toggle(model.text("corners.all"), isOn: Binding(get: { model.policy.allConfiguredCorners }, set: { allConfigured in
                        model.policy.allConfiguredCorners = allConfigured
                        if !allConfigured { model.policy.selectedCorners.formIntersection(Set(model.corners.filter(\.isSleep).map(\.id))) }
                    }))
                    if !model.policy.allConfiguredCorners {
                        ForEach(model.corners.filter(\.isSleep)) { corner in
                            Toggle(model.text("corner.\(corner.id)"), isOn: cornerBinding(corner.id)).padding(.leading, 20)
                        }
                    }
                }
                SealNote(text: model.text("corners.lockNote"))
                Button(model.text("action.openSettings")) { model.send(.openHotCorners) }
            }
        }.disabled(model.isBusy)
    }
    private func triggerBinding(_ trigger: UITrigger) -> Binding<Bool> {
        Binding(get: { model.policy.sources.contains(trigger) }, set: { enabled in
            if enabled { model.policy.sources.insert(trigger) } else { model.policy.sources.remove(trigger) }
        })
    }
    private func cornerBinding(_ id: String) -> Binding<Bool> {
        Binding(get: { model.policy.selectedCorners.contains(id) }, set: { enabled in
            if enabled { model.policy.selectedCorners.insert(id) } else { model.policy.selectedCorners.remove(id) }
        })
    }

    private var power: some View {
        VStack(spacing: SleepSealTheme.sectionSpacing) {
            if model.powerConflict {
                SealSection(model.text("power.conflict")) {
                    Button(model.text("power.refreshDiscard")) {
                        model.powerDrafts.removeAll(); model.send(.refresh)
                    }.disabled(model.isBusy)
                }
            }
            if !model.powerLoaded {
                SealSection(model.text("power.loading")) {
                    Button(model.text("action.refresh")) { model.send(.refresh) }.disabled(model.isBusy)
                }
            } else {
                ForEach(UIPowerScope.allCases) { scope in
                    powerProfile(scope)
                }
            }
            SealNote(text: model.text("power.deep.help"))
            SealNote(text: model.text("power.assertions"))
            if let key = model.powerErrorKey { Label(model.text(key), systemImage: "exclamationmark.triangle").foregroundStyle(.red) }
            if model.powerDirty { Text(model.text("power.unsaved")).font(.callout).foregroundStyle(.secondary) }
            HStack {
                Button(model.text("action.restorePower")) { confirmPowerRestore = true }
                    .disabled(!model.hasPowerBackup || model.isBusy || model.guardPending)
                Spacer()
                Button(model.text("action.apply")) { model.applyPower() }
                    .buttonStyle(.borderedProminent).disabled(!model.powerDirty || model.isBusy || model.powerConflict)
            }
            Text(model.text("power.restore.help")).font(.caption).foregroundStyle(.secondary)
        }
    }
    @ViewBuilder private func powerProfile(_ scope: UIPowerScope) -> some View {
        SealSection(model.text("power.\(scope.rawValue)")) {
            if let profile = model.powerProfiles[scope], profile.available {
                if profile.values["displaysleep"] != nil { TimerField(model: model, scope: scope, key: "displaysleep", titleKey: "power.display") }
                if profile.values["sleep"] != nil { Divider(); TimerField(model: model, scope: scope, key: "sleep", titleKey: "power.sleep") }
                if let key = profile.modeKey, profile.values[key] != nil {
                    Divider()
                    HStack {
                        Text(model.text("power.mode")).frame(maxWidth: .infinity, alignment: .leading)
                        Picker(model.text("power.mode"), selection: Binding(get: { model.draft(scope, key) }, set: { model.setDraft($0, scope: scope, key: key) })) {
                            ForEach(profile.supportedModes, id: \.self) { mode in Text(model.text("power.mode.\(mode)")).tag(String(mode)) }
                        }.labelsHidden().frame(width: 190).disabled(model.guardPending || profile.supportedModes.isEmpty)
                    }
                    if model.guardPending { SealNote(text: model.text("power.modeLocked"), symbol: "lock") }
                }
                Divider()
                HStack {
                    Text(model.text("power.deep"))
                    Spacer()
                    Label(model.text("power.managed"), systemImage: "lock").foregroundStyle(.secondary)
                }.accessibilityElement(children: .combine)
            } else { Text(model.text("power.unavailable")).foregroundStyle(.secondary) }
        }.disabled(model.isBusy)
    }

    private var diagnostics: some View {
        VStack(spacing: SleepSealTheme.sectionSpacing) {
            SealSection(model.text("diagnostics.permissions")) {
                if model.permissions.isEmpty { Text(model.text("permission.checking")).foregroundStyle(.secondary) }
                ForEach(model.permissions) { permission in
                    HStack(alignment: .top) {
                        Image(systemName: permission.ready ? "checkmark.circle.fill" : "exclamationmark.triangle")
                            .foregroundStyle(permission.ready ? SleepSealTheme.accent : Color.orange)
                        VStack(alignment: .leading, spacing: 4) {
                            Text(model.text(permission.titleKey)).font(.body.weight(.medium))
                            Text(model.text(permission.detailKey)).font(.callout).foregroundStyle(.secondary)
                        }
                        Spacer()
                        if !permission.ready, let action = permission.action { Button(model.text("action.repair")) { model.send(action) }.disabled(model.isBusy) }
                    }.accessibilityElement(children: .contain)
                }
            }
            SealSection(model.text("diagnostics.recovery")) {
                Text(model.text(model.guardPending ? "diagnostics.pending" : "diagnostics.noPending")).foregroundStyle(.secondary)
                Button(model.text("action.restore")) { model.send(.restoreProtection) }.disabled(!model.guardPending || model.isBusy)
            }
            SealSection(model.text("diagnostics.blockers")) {
                if !model.blockersLoaded { Text(model.text("diagnostics.blockers.loading")).foregroundStyle(.secondary) }
                else if model.sleepBlockers.isEmpty { Text(model.text("diagnostics.noBlockers")).foregroundStyle(.secondary) }
                else { ForEach(Array(model.sleepBlockers.enumerated()), id: \.offset) { _, value in Text(value).font(.callout).textSelection(.enabled) } }
                SealNote(text: model.text("diagnostics.blockers.help"))
            }
            HStack {
                Button(model.text("action.export")) { model.send(.exportDiagnostics) }.disabled(model.isBusy)
                Text(model.text("diagnostics.export.help")).font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    private var settings: some View {
        VStack(spacing: SleepSealTheme.sectionSpacing) {
            SealSection(model.text("settings.language")) {
                Picker(model.text("settings.language"), selection: Binding(get: { model.language }, set: { model.send(.setLanguage($0)) })) {
                    ForEach(UILanguage.allCases) { language in Text(model.text("language.\(language.rawValue)")).tag(language) }
                }.labelsHidden().frame(maxWidth: 260, alignment: .leading)
                Text(model.text("settings.language.help")).font(.callout).foregroundStyle(.secondary)
            }
            SealSection(model.text("permission.service")) {
                Toggle(model.text("settings.login"), isOn: Binding(get: { model.loginEnabled }, set: { model.send(.setLogin($0)) }))
                    .disabled(model.isBusy)
                Text(model.text("settings.login.help")).font(.callout).foregroundStyle(.secondary)
                Divider()
                Toggle(model.text("settings.pause"), isOn: Binding(get: { model.isPaused }, set: { model.send(.setPaused($0)) }))
                    .disabled(model.isBusy || !model.isEnabled)
                Text(model.text("settings.pause.help")).font(.callout).foregroundStyle(.secondary)
            }
            SealSection(model.text("settings.about")) {
                HStack { Text("SleepSeal").font(.headline); Spacer(); Text(model.appVersion).foregroundStyle(.secondary) }
                Text(model.text("settings.about.help")).font(.callout).foregroundStyle(.secondary)
                Label(model.text("app.beta"), systemImage: "hammer").font(.caption).foregroundStyle(.secondary)
            }
            SealSection(model.text("settings.uninstall"), subtitle: model.text("settings.uninstall.help")) {
                Button(model.text("action.uninstall"), role: .destructive) { confirmUninstall = true }.disabled(model.isBusy)
            }
        }
    }

    private var onboarding: some View {
        VStack(alignment: .leading, spacing: 20) {
            Image(systemName: "moon.circle.fill").font(.system(size: 48)).foregroundStyle(SleepSealTheme.accent).accessibilityHidden(true)
            Text(model.text("onboarding.title")).font(.largeTitle.weight(.semibold))
            Text(model.text("onboarding.intro")).fixedSize(horizontal: false, vertical: true)
            Label(model.text("policy.all"), systemImage: "checkmark.shield.fill").font(.headline).foregroundStyle(SleepSealTheme.accent)
            Text(model.text("onboarding.rules")).font(.callout).foregroundStyle(.secondary)
            SealNote(text: model.text("onboarding.permission"))
            SealNote(text: model.text("onboarding.note"), symbol: "wifi.slash")
            HStack {
                Button(model.text("onboarding.later")) { model.onboardingRequired = false }
                Spacer()
                Button(model.text("action.enable")) { model.send(.enableProtection) }
                    .buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction).disabled(model.isBusy)
            }
        }.padding(30).frame(width: 510).interactiveDismissDisabled()
    }

    private var uninstallSheet: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text(model.text("uninstall.title")).font(.title2.weight(.semibold))
            Text(model.text("uninstall.message")).fixedSize(horizontal: false, vertical: true)
            Toggle(model.text("uninstall.restorePower"), isOn: $restorePowerOnUninstall).disabled(!model.hasPowerBackup)
            HStack {
                Button(model.text("action.cancel")) { confirmUninstall = false }.keyboardShortcut(.cancelAction)
                Spacer()
                Button(model.text("action.confirmUninstall"), role: .destructive) {
                    confirmUninstall = false
                    model.send(.uninstall(restorePower: restorePowerOnUninstall))
                }
            }
        }.padding(26).frame(width: 480)
    }
}

/// The precise manual-sleep entry is a real AppKit control. Besides standard
/// keyboard/VoiceOver semantics, its identity can be inspected in a local
/// mock-window test without enabling system-wide assistive access.
private struct NativeSleepButton: NSViewRepresentable {
    let title: String
    let enabled: Bool
    let action: () -> Void
    func makeCoordinator() -> Coordinator { Coordinator(action: action) }
    func makeNSView(context: Context) -> NSButton {
        let button = NSButton(title: title, target: context.coordinator, action: #selector(Coordinator.press))
        button.bezelStyle = .rounded
        button.image = NSImage(systemSymbolName: "moon.zzz", accessibilityDescription: nil)
        button.imagePosition = .imageLeading
        button.setContentHuggingPriority(.required, for: .horizontal)
        button.setContentHuggingPriority(.required, for: .vertical)
        button.setAccessibilityIdentifier("SleepSeal.sleepNow")
        return button
    }
    func updateNSView(_ button: NSButton, context: Context) {
        button.title = title
        button.setAccessibilityElement(true)
        button.setAccessibilityLabel(title)
        button.isEnabled = enabled
        context.coordinator.action = action
    }
    final class Coordinator: NSObject {
        var action: () -> Void
        init(action: @escaping () -> Void) { self.action = action }
        @objc func press() { action() }
    }
}

private struct TimerField: View {
    @ObservedObject var model: DashboardModel
    let scope: UIPowerScope
    let key: String
    let titleKey: String
    @State private var custom = false
    private let choices = [0, 1, 2, 5, 10, 15, 30, 60, 120, 240]
    private var value: Int? { Int(model.draft(scope, key)) }
    private var selection: String {
        if custom { return "custom" }
        if let value, choices.contains(value) { return String(value) }
        if let value, value > 1440 { return "special" }
        return "custom"
    }
    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            Text(model.text(titleKey)).frame(maxWidth: .infinity, alignment: .leading)
            VStack(alignment: .trailing, spacing: 8) {
                Picker(model.text(titleKey), selection: Binding(get: { selection }, set: { selected in
                    custom = selected == "custom"
                    if Int(selected) != nil { model.setDraft(selected, scope: scope, key: key) }
                })) {
                    ForEach(choices, id: \.self) { number in
                        Text(number == 0 ? model.text("power.never") : String(format: model.text("power.minuteFormat"), String(number))).tag(String(number))
                    }
                    if let value, value > 1440 {
                        Text(String(format: model.text("power.special"), String(value))).tag("special")
                    }
                    Text(model.text("power.custom")).tag("custom")
                }.labelsHidden().frame(width: 190)
                if selection == "custom" {
                    HStack(spacing: 6) {
                        TextField(model.text(titleKey), text: Binding(get: { model.draft(scope, key) }, set: { model.setDraft($0, scope: scope, key: key) }))
                            .textFieldStyle(.roundedBorder).frame(width: 90)
                            .accessibilityHint(model.text("power.validation"))
                        Text(model.text("power.minutes")).font(.callout).foregroundStyle(.secondary)
                    }
                }
            }
        }
    }
}

private struct CornerMap: View {
    @ObservedObject var model: DashboardModel
    var body: some View {
        VStack(spacing: 12) {
            HStack(alignment: .top) { corner("tl"); Spacer(minLength: 16); corner("tr") }
            RoundedRectangle(cornerRadius: 8)
                .fill(SleepSealTheme.background)
                .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(SleepSealTheme.separator))
                .overlay(Image(systemName: "display").font(.system(size: 32)).foregroundStyle(.secondary).accessibilityHidden(true))
                .frame(height: 70).padding(.horizontal, 45).accessibilityHidden(true)
            HStack(alignment: .top) { corner("bl"); Spacer(minLength: 16); corner("br") }
        }
        .padding(14)
        .background(SleepSealTheme.background.opacity(0.5), in: RoundedRectangle(cornerRadius: 8))
    }
    private func corner(_ id: String) -> some View {
        let value = model.corners.first(where: { $0.id == id }) ?? UICorner(id: id)
        let actionKey = value.action.flatMap { action in action <= 1 ? nil : "corner.action.\(action)" } ?? "corner.action.none"
        let resolved = model.text(actionKey)
        let action = resolved == actionKey ? model.text("corner.action.other") : resolved
        return VStack(alignment: id.hasSuffix("l") ? .leading : .trailing, spacing: 4) {
            Label(model.text("corner.\(id)"), systemImage: value.isSleep ? "moon.fill" : "circle.dotted")
                .font(.callout.weight(.medium)).foregroundStyle(value.isSleep ? SleepSealTheme.accent : Color.secondary)
            Text(action).font(.caption).foregroundStyle(.secondary)
            if !value.modifierSymbols.isEmpty { Text(value.modifierSymbols).font(.system(.caption, design: .monospaced)) }
        }.frame(maxWidth: .infinity, alignment: id.hasSuffix("l") ? .leading : .trailing)
            .accessibilityElement(children: .combine)
    }
}
