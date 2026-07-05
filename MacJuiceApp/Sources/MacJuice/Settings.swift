import Foundation
import ServiceManagement

enum LabelStyle: String, CaseIterable, Identifiable {
    case icon, percent, watts, both
    var id: String { rawValue }

    var title: String {
        switch self {
        case .icon: "Icon only"
        case .percent: "Percentage"
        case .watts: "Power draw"
        case .both: "Percentage | Power"
        }
    }

    /// Styles whose number drifts without a power-source notification and
    /// therefore need the slow coalesced label refresh.
    var showsWatts: Bool { self == .watts || self == .both }
}

@MainActor
final class Settings: ObservableObject {
    static let shared = Settings()

    @Published var labelStyle: LabelStyle {
        didSet { UserDefaults.standard.set(labelStyle.rawValue, forKey: "labelStyle") }
    }

    /// Keep the panel floating above other windows instead of dismissing on
    /// outside clicks / Esc.
    @Published var pinPanel: Bool {
        didSet { UserDefaults.standard.set(pinPanel, forKey: "pinPanel") }
    }

    @Published var notifyLowBattery: Bool {
        didSet { UserDefaults.standard.set(notifyLowBattery, forKey: "notifyLowBattery") }
    }
    @Published var notifyFullyCharged: Bool {
        didSet { UserDefaults.standard.set(notifyFullyCharged, forKey: "notifyFullyCharged") }
    }
    @Published var notifyHighTemp: Bool {
        didSet { UserDefaults.standard.set(notifyHighTemp, forKey: "notifyHighTemp") }
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
        func flag(_ key: String) -> Bool {
            UserDefaults.standard.object(forKey: key) == nil
                ? true : UserDefaults.standard.bool(forKey: key)
        }
        notifyLowBattery = flag("notifyLowBattery")
        notifyFullyCharged = flag("notifyFullyCharged")
        notifyHighTemp = flag("notifyHighTemp")
        pinPanel = UserDefaults.standard.bool(forKey: "pinPanel")
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
