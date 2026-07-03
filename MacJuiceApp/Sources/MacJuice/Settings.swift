import Foundation
import ServiceManagement

enum LabelStyle: String, CaseIterable, Identifiable {
    case icon, percent, watts
    var id: String { rawValue }

    var title: String {
        switch self {
        case .icon: "Icon only"
        case .percent: "Percentage"
        case .watts: "Power draw"
        }
    }
}

@MainActor
final class Settings: ObservableObject {
    static let shared = Settings()

    @Published var labelStyle: LabelStyle {
        didSet { UserDefaults.standard.set(labelStyle.rawValue, forKey: "labelStyle") }
    }

    @Published var launchAtLogin: Bool {
        didSet {
            guard launchAtLogin != (SMAppService.mainApp.status == .enabled) else { return }
            do {
                if launchAtLogin {
                    try SMAppService.mainApp.register()
                } else {
                    try SMAppService.mainApp.unregister()
                }
            } catch {
                NSLog("MacJuice: login item change failed: \(error.localizedDescription)")
            }
            launchAtLogin = SMAppService.mainApp.status == .enabled
        }
    }

    private init() {
        labelStyle = UserDefaults.standard.string(forKey: "labelStyle")
            .flatMap(LabelStyle.init(rawValue:)) ?? .watts
        launchAtLogin = SMAppService.mainApp.status == .enabled
    }

    /// Register once on first launch from a stable location, honoring any
    /// later manual opt-out.
    func autoRegisterLoginItemIfNeeded() {
        let key = "didAutoRegisterLoginItem"
        guard !UserDefaults.standard.bool(forKey: key),
              Bundle.main.bundlePath.hasPrefix("/Applications/") else { return }
        UserDefaults.standard.set(true, forKey: key)
        if SMAppService.mainApp.status != .enabled {
            try? SMAppService.mainApp.register()
        }
        launchAtLogin = SMAppService.mainApp.status == .enabled
    }
}
