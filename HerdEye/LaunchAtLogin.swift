import AppKit
import Foundation
import Observation
import ServiceManagement

/// Registers the running HerdEye app as a login item.
/// `SMAppService` is the source of truth, including changes made in System Settings.
@Observable @MainActor
final class LaunchAtLoginController {
    /// True when launch at login is enabled, or registered and waiting for approval.
    private(set) var isOn = false
    /// True when macOS has the login item but will not launch it until the user allows it.
    private(set) var needsApproval = false
    /// Latest failure from register or unregister. Cleared after a successful change.
    private(set) var errorMessage: String?

    private var activationObserver: NSObjectProtocol?

    init() {
        refresh()
    }

    /// Keep the toggle aligned with System Settings when HerdEye becomes active again.
    func startObservingAppActivation() {
        guard activationObserver == nil else { return }
        activationObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didBecomeActiveNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.refresh()
            }
        }
    }

    func refresh() {
        apply(SMAppService.mainApp.status)
    }

    func setEnabled(_ enabled: Bool) {
        let service = SMAppService.mainApp
        do {
            if enabled {
                switch service.status {
                case .enabled, .requiresApproval:
                    break
                case .notRegistered, .notFound:
                    try service.register()
                @unknown default:
                    try service.register()
                }
            } else if service.status != .notRegistered {
                try service.unregister()
            }
            errorMessage = nil
        } catch {
            errorMessage = Self.message(for: error)
        }
        refresh()
        if needsApproval {
            errorMessage = nil
        }
    }

    func openLoginItemsSettings() {
        SMAppService.openSystemSettingsLoginItems()
    }

    private func apply(_ status: SMAppService.Status) {
        switch status {
        case .enabled:
            isOn = true
            needsApproval = false
        case .requiresApproval:
            isOn = true
            needsApproval = true
        case .notRegistered, .notFound:
            isOn = false
            needsApproval = false
        @unknown default:
            isOn = false
            needsApproval = false
        }
    }

    /// Hide errors that the status line already explains, and translate signature failures.
    private static func message(for error: Error) -> String? {
        switch (error as NSError).code {
        case Int(kSMErrorLaunchDeniedByUser),
             Int(kSMErrorAlreadyRegistered),
             Int(kSMErrorJobNotFound):
            return nil
        case Int(kSMErrorInvalidSignature):
            return "Launch at login needs a signed copy of HerdEye."
        default:
            return error.localizedDescription
        }
    }
}
