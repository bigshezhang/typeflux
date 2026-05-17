import AppKit
import Foundation
import os

extension Notification.Name {
    /// Posted after account-backed Typeflux Cloud model defaults have been
    /// applied to ``SettingsStore``.
    static let cloudAccountModelDefaultsDidApply = Notification.Name(
        "CloudLoginSyncCoordinator.cloudAccountModelDefaultsDidApply"
    )
}

@MainActor
protocol CloudModelDefaultsPrompting: AnyObject {
    func confirmSwitchToCloudDefaults() -> Bool
    func showCloudDefaultsApplied()
}

@MainActor
final class CloudModelDefaultsAlertPresenter: CloudModelDefaultsPrompting {
    func confirmSwitchToCloudDefaults() -> Bool {
        let alert = NSAlert()
        alert.alertStyle = .informational
        alert.messageText = L("cloud.subscriptionSwitch.title")
        alert.informativeText = L("cloud.subscriptionSwitch.body")
        alert.addButton(withTitle: L("cloud.subscriptionSwitch.confirm"))
        alert.addButton(withTitle: L("cloud.subscriptionSwitch.keepCurrent"))
        NSApp.activate(ignoringOtherApps: true)
        return alert.runModal() == .alertFirstButtonReturn
    }

    func showCloudDefaultsApplied() {
        let alert = NSAlert()
        alert.alertStyle = .informational
        alert.messageText = L("cloud.subscriptionSwitch.successTitle")
        alert.informativeText = L("cloud.subscriptionSwitch.successBody")
        alert.addButton(withTitle: L("common.ok"))
        NSApp.activate(ignoringOtherApps: true)
        _ = alert.runModal()
    }
}

/// Offers to switch STT and LLM selections to the Typeflux Cloud providers
/// after explicit login, or after checkout confirms a paid Cloud subscription.
///
/// Listens for `.authDidLogin` and `.authCheckoutSubscriptionDidBecomeEntitled`,
/// and is intentionally silent when both providers already point at Cloud.
@MainActor
final class CloudLoginSyncCoordinator {
    private let settingsStore: SettingsStore
    private let promptPresenter: CloudModelDefaultsPrompting
    private let logger = Logger(subsystem: "ai.gulu.app.typeflux", category: "CloudLoginSyncCoordinator")
    private var observers: [NSObjectProtocol] = []

    init(
        settingsStore: SettingsStore,
        promptPresenter: CloudModelDefaultsPrompting? = nil
    ) {
        self.settingsStore = settingsStore
        self.promptPresenter = promptPresenter ?? CloudModelDefaultsAlertPresenter()
        observers.append(NotificationCenter.default.addObserver(
            forName: .authDidLogin,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            Task { @MainActor [weak self] in
                guard notification.object is AuthState else {
                    self?.logger.debug("Login notification missing AuthState; skipping cloud defaults prompt")
                    return
                }
                self?.offerCloudDefaultsIfNeeded()
            }
        })
        observers.append(NotificationCenter.default.addObserver(
            forName: .authCheckoutSubscriptionDidBecomeEntitled,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.offerCloudDefaultsIfNeeded()
            }
        })
    }

    deinit {
        for observer in observers {
            NotificationCenter.default.removeObserver(observer)
        }
    }

    /// Exposed for tests; in production triggered after login, or after checkout
    /// confirms a newly entitled or newly paid subscription.
    func offerCloudDefaultsIfNeeded() {
        let alreadySTTCloud = settingsStore.sttProvider == .typefluxOfficial
        let alreadyLLMCloud = settingsStore.llmProvider == .openAICompatible
            && settingsStore.llmRemoteProvider == .typefluxCloud

        guard !(alreadySTTCloud && alreadyLLMCloud) else {
            logger.debug("Cloud providers already selected; skipping cloud defaults prompt")
            return
        }

        guard promptPresenter.confirmSwitchToCloudDefaults() else {
            logger.debug("User kept existing model providers after subscription")
            return
        }

        applyCloudDefaults()
        promptPresenter.showCloudDefaultsApplied()
    }

    private func applyCloudDefaults() {
        settingsStore.sttProvider = .typefluxOfficial
        settingsStore.localOptimizationEnabled = false
        settingsStore.llmProvider = .openAICompatible
        settingsStore.llmRemoteProvider = .typefluxCloud
        settingsStore.applyDefaultPersonaIfLLMConfigured()
        NotificationCenter.default.post(name: .cloudAccountModelDefaultsDidApply, object: settingsStore)
    }
}
