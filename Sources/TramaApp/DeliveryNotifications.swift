import Foundation
import Combine
import UserNotifications
import SwiftUI

/// Authorization is requested only by the explicit settings button. No content
/// from an agent, project, path, or terminal is copied into a system alert.
@MainActor
final class DeliveryNotifications: ObservableObject {
    @Published private(set) var enabled: Bool
    @Published private(set) var requesting = false
    @Published private(set) var error: String?
    private let defaults: UserDefaults
    private let preferenceKey = "trama.deliveryNotifications.enabled"

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        enabled = defaults.bool(forKey: preferenceKey)
    }

    func enableExplicitly() async {
        guard !requesting else { return }
        // UNUserNotificationCenter requires an application bundle. Tests and
        // command-line launches must never trigger a permission dialog.
        guard Bundle.main.bundleURL.pathExtension == "app",
              ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] == nil else {
            error = "Abra o bundle Trama.app para ativar alertas do macOS."
            return
        }
        requesting = true
        defer { requesting = false }
        do {
            let granted = try await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound])
            enabled = granted
            defaults.set(granted, forKey: preferenceKey)
            error = granted ? nil : "Alertas não autorizados. Você pode revisar a permissão nos Ajustes do macOS."
        } catch {
            self.error = "Não foi possível ativar alertas: \(error.localizedDescription)"
        }
    }

    func disable() {
        enabled = false
        defaults.set(false, forKey: preferenceKey)
        error = nil
    }

    func refreshPreference() {
        enabled = defaults.bool(forKey: preferenceKey)
    }

    func announceNewItems(_ count: Int) async {
        // Another window may have opted out since this object was created.
        refreshPreference()
        guard count > 0, enabled, Bundle.main.bundleURL.pathExtension == "app",
              ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] == nil else { return }
        let content = UNMutableNotificationContent()
        content.title = "Trama precisa da sua atenção"
        content.body = "Há novos itens na inbox local. Abra o Trama para revisar."
        do {
            try await UNUserNotificationCenter.current().add(UNNotificationRequest(
                identifier: "trama-inbox-\(UUID().uuidString)", content: content, trigger: nil))
        } catch { self.error = "Não foi possível apresentar o alerta: \(error.localizedDescription)" }
    }
}

struct DeliveryNotificationSettings: View {
    @ObservedObject var notifications: DeliveryNotifications

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Alertas do macOS").accessibilityAddTraits(.isHeader)
            Text("Opcional. O alerta diz apenas que há novos itens na inbox, sem nomes, tarefas, projetos ou conteúdo de terminal.")
                .foregroundStyle(TerminalTheme.secondary)
            HStack {
                Text(notifications.enabled ? "Alertas ativados" : "Alertas desativados")
                Spacer()
                if notifications.enabled {
                    Button("Desativar alertas") { notifications.disable() }
                } else {
                    Button("Ativar alertas do macOS…") { Task { await notifications.enableExplicitly() } }
                        .disabled(notifications.requesting)
                }
                if notifications.requesting { ProgressView().controlSize(.small) }
            }
            if let error = notifications.error {
                Text(error).foregroundStyle(TerminalTheme.warning).textSelection(.enabled)
            }
        }
        .onAppear { notifications.refreshPreference() }
        .onReceive(NotificationCenter.default.publisher(for: UserDefaults.didChangeNotification)) { _ in
            notifications.refreshPreference()
        }
    }
}
