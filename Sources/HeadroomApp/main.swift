import AppKit
import Combine
import HeadroomCore
import SwiftUI

private enum HeadroomTheme {
    static let background = Color(red: 0.086, green: 0.078, blue: 0.075)
    static let surface = Color(red: 0.122, green: 0.110, blue: 0.098)
    static let surfaceRaised = Color(red: 0.180, green: 0.165, blue: 0.145)
    static let border = Color(red: 0.271, green: 0.247, blue: 0.216)
    static let text = Color(red: 0.953, green: 0.933, blue: 0.902)
    static let secondary = Color(red: 0.718, green: 0.678, blue: 0.620)
    static let muted = Color(red: 0.655, green: 0.620, blue: 0.573)
    static let accent = Color(red: 0.878, green: 0.643, blue: 0.345)
    static let danger = Color(red: 0.910, green: 0.416, blue: 0.361)

    static let space4: CGFloat = 4
    static let space8: CGFloat = 8
    static let space12: CGFloat = 12
    static let space16: CGFloat = 16
    static let space24: CGFloat = 24
    static let radiusSmall: CGFloat = 10
    static let radiusMedium: CGFloat = 16
}

@MainActor
private final class HeadroomViewModel: ObservableObject {
    @Published var configuration: HeadroomConfiguration
    @Published var status: HeadroomStatus?
    @Published var isRefreshing = false

    private let configurationStore: ConfigurationStore
    private let statusStore: StatusStore
    private let meterReader = MeterReader()

    init(
        configurationStore: ConfigurationStore = ConfigurationStore(),
        statusStore: StatusStore = StatusStore()
    ) {
        self.configurationStore = configurationStore
        self.statusStore = statusStore
        self.configuration = (try? configurationStore.load()) ?? .default
        self.status = try? statusStore.load()
    }

    var menuLabel: String {
        guard let snapshot = status?.snapshot,
              let lowest = snapshot.windows.map(\.remainingPercent).min()
        else { return "Headroom" }
        return "\(lowest)%"
    }

    func setEnabled(_ enabled: Bool) {
        configuration.enabled = enabled
        persistConfiguration()
    }

    func setReserve(_ reserve: Int) {
        configuration.reservePercent = min(max(reserve, 1), 50)
        persistConfiguration()
    }

    func refresh() {
        guard !isRefreshing else { return }
        isRefreshing = true
        Task {
            do {
                let snapshot = try await meterReader.read()
                let newStatus = HeadroomStatus(snapshot: snapshot, error: nil)
                try? statusStore.save(newStatus)
                status = newStatus
            } catch {
                let newStatus = HeadroomStatus(snapshot: nil, error: error.localizedDescription)
                try? statusStore.save(newStatus)
                status = newStatus
            }
            isRefreshing = false
        }
    }

    private func persistConfiguration() {
        try? configurationStore.save(configuration)
    }
}

@main
private struct HeadroomApp: App {
    @StateObject private var model = HeadroomViewModel()

    var body: some Scene {
        MenuBarExtra {
            HeadroomPanel(model: model)
        } label: {
            Label(model.menuLabel, systemImage: "gauge.with.dots.needle.67percent")
        }
        .menuBarExtraStyle(.window)
    }
}

private struct HeadroomPanel: View {
    @ObservedObject var model: HeadroomViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: HeadroomTheme.space16) {
            header
            windows
            reserveControl
            footer
        }
        .padding(HeadroomTheme.space16)
        .frame(width: 340)
        .background(HeadroomTheme.background)
        .foregroundStyle(HeadroomTheme.text)
        .task {
            if model.status == nil { model.refresh() }
        }
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: HeadroomTheme.space4) {
                Text("HEADROOM")
                    .font(.system(size: 10, weight: .semibold, design: .rounded))
                    .tracking(1.6)
                    .foregroundStyle(HeadroomTheme.muted)
                Text("Keep something in reserve.")
                    .font(.system(size: 20, weight: .semibold, design: .rounded))
            }
            Spacer()
            Toggle("Protection", isOn: Binding(
                get: { model.configuration.enabled },
                set: { value in model.setEnabled(value) }
            ))
            .labelsHidden()
            .toggleStyle(.switch)
            .tint(HeadroomTheme.accent)
            .accessibilityLabel("Quota protection")
        }
    }

    @ViewBuilder
    private var windows: some View {
        if model.isRefreshing, model.status == nil {
            statusCard {
                HStack(spacing: HeadroomTheme.space8) {
                    ProgressView().controlSize(.small).tint(HeadroomTheme.accent)
                    Text("Reading Codex quota…")
                        .foregroundStyle(HeadroomTheme.secondary)
                }
            }
        } else if let snapshot = model.status?.snapshot, !snapshot.windows.isEmpty {
            statusCard {
                VStack(spacing: HeadroomTheme.space12) {
                    ForEach(snapshot.windows) { window in
                        WindowRow(window: window, reserve: model.configuration.reservePercent)
                    }
                }
            }
        } else if let error = model.status?.error {
            statusCard {
                VStack(alignment: .leading, spacing: HeadroomTheme.space8) {
                    Label("Meter unavailable", systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(HeadroomTheme.danger)
                        .fontWeight(.semibold)
                    Text(error)
                        .font(.system(size: 12))
                        .foregroundStyle(HeadroomTheme.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    Text("Protection fails open while the meter is unavailable.")
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(HeadroomTheme.muted)
                }
            }
        } else {
            statusCard {
                Text("Press Refresh to read your Codex quota.")
                    .foregroundStyle(HeadroomTheme.secondary)
            }
        }
    }

    private func statusCard<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        content()
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(HeadroomTheme.space16)
            .background(HeadroomTheme.surface)
            .clipShape(RoundedRectangle(cornerRadius: HeadroomTheme.radiusMedium))
            .overlay {
                RoundedRectangle(cornerRadius: HeadroomTheme.radiusMedium)
                    .stroke(HeadroomTheme.border, lineWidth: 1)
            }
    }

    private var reserveControl: some View {
        VStack(alignment: .leading, spacing: HeadroomTheme.space8) {
            HStack {
                Text("RESERVE")
                    .font(.system(size: 10, weight: .semibold, design: .rounded))
                    .tracking(1.6)
                    .foregroundStyle(HeadroomTheme.muted)
                Spacer()
                Text("\(model.configuration.reservePercent)%")
                    .font(.system(size: 13, weight: .semibold, design: .monospaced))
                    .foregroundStyle(HeadroomTheme.accent)
            }
            Slider(
                value: Binding(
                    get: { Double(model.configuration.reservePercent) },
                    set: { model.setReserve(Int($0.rounded())) }
                ),
                in: 1...50,
                step: 1
            )
            .tint(HeadroomTheme.accent)
            .accessibilityLabel("Reserved quota percentage")
            Text("Stops at the first supported Codex boundary reporting this much remaining.")
                .font(.system(size: 11))
                .foregroundStyle(HeadroomTheme.muted)
        }
    }

    private var footer: some View {
        HStack(spacing: HeadroomTheme.space8) {
            Button {
                model.refresh()
            } label: {
                Label(model.isRefreshing ? "Refreshing" : "Refresh", systemImage: "arrow.clockwise")
            }
            .buttonStyle(QuietButtonStyle())
            .disabled(model.isRefreshing)

            Spacer()

            Button("Quit") { NSApplication.shared.terminate(nil) }
                .buttonStyle(QuietButtonStyle())
        }
    }
}

private actor MeterReader {
    func read() throws -> RateLimitSnapshot {
        let client = try CodexAppServerClient()
        return try client.readRateLimits()
    }
}

private struct WindowRow: View {
    let window: RateLimitWindow
    let reserve: Int

    private var isProtected: Bool { window.remainingPercent <= reserve }

    var body: some View {
        VStack(spacing: HeadroomTheme.space8) {
            HStack {
                VStack(alignment: .leading, spacing: HeadroomTheme.space4) {
                    Text(window.displayName.uppercased())
                        .font(.system(size: 10, weight: .semibold, design: .rounded))
                        .tracking(1.4)
                        .foregroundStyle(HeadroomTheme.muted)
                    Text("\(window.remainingPercent)% remaining")
                        .font(.system(size: 17, weight: .semibold, design: .monospaced))
                }
                Spacer()
                if isProtected {
                    Text("RESERVED")
                        .font(.system(size: 9, weight: .bold, design: .rounded))
                        .tracking(1.1)
                        .foregroundStyle(HeadroomTheme.accent)
                        .padding(.horizontal, HeadroomTheme.space8)
                        .padding(.vertical, HeadroomTheme.space4)
                        .background(HeadroomTheme.surfaceRaised)
                        .clipShape(Capsule())
                }
            }
            GeometryReader { proxy in
                ZStack(alignment: .leading) {
                    Capsule().fill(HeadroomTheme.surfaceRaised)
                    Capsule()
                        .fill(isProtected ? HeadroomTheme.danger : HeadroomTheme.accent)
                        .frame(width: proxy.size.width * CGFloat(window.remainingPercent) / 100)
                }
            }
            .frame(height: 6)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("\(window.displayName) quota")
            .accessibilityValue("\(window.remainingPercent) percent remaining")
        }
    }
}

private struct QuietButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 12, weight: .semibold, design: .rounded))
            .foregroundStyle(HeadroomTheme.text)
            .padding(.horizontal, HeadroomTheme.space12)
            .padding(.vertical, HeadroomTheme.space8)
            .background(configuration.isPressed ? HeadroomTheme.surfaceRaised : HeadroomTheme.surface)
            .clipShape(RoundedRectangle(cornerRadius: HeadroomTheme.radiusSmall))
            .overlay {
                RoundedRectangle(cornerRadius: HeadroomTheme.radiusSmall)
                    .stroke(HeadroomTheme.border, lineWidth: 1)
            }
            .opacity(configuration.isPressed ? 0.82 : 1)
    }
}
