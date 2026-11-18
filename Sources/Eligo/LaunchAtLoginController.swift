import Combine
import ServiceManagement

protocol LaunchItemService {
    var status: SMAppService.Status { get }

    func register() throws
    func unregister() throws
}

extension SMAppService: LaunchItemService {}

@MainActor
final class LaunchAtLoginController: ObservableObject {
    @Published private(set) var status: SMAppService.Status
    @Published private(set) var lastErrorMessage: String?

    private let service: any LaunchItemService

    init(service: any LaunchItemService = SMAppService.mainApp) {
        self.service = service
        status = service.status
    }

    var isEnabled: Bool {
        status == .enabled
    }

    var requiresApproval: Bool {
        status == .requiresApproval
    }

    var isAvailable: Bool {
        status != .notFound
    }

    func refresh() {
        status = service.status
    }

    @discardableResult
    func setEnabled(_ isEnabled: Bool) -> Bool {
        lastErrorMessage = nil

        do {
            if isEnabled {
                try service.register()
            } else {
                try service.unregister()
            }
            refresh()
            return true
        } catch {
            lastErrorMessage = error.localizedDescription
            AppLog.app.error("Failed to update Launch at Login: \(error.localizedDescription, privacy: .public)")
            refresh()
            return false
        }
    }

    func openLoginItemsSettings() {
        SMAppService.openSystemSettingsLoginItems()
    }
}
