import SwiftUI

/// Main screen: the bike, the connection state, the last button press and the button map.
struct HomeView: View {
    @EnvironmentObject private var client: SABClient

    var body: some View {
        ScrollView {
            VStack(spacing: 16) {
                HeroCard()
                LastPressCard()
                ButtonMapCard()
                Text("Turn the key and ScooterLink connects by itself. Keep it in the app switcher: iOS won't relaunch an app you swipe away.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 24)
                    .padding(.top, 4)
            }
            .padding(16)
        }
        .background(Backdrop(status: client.status))
    }
}

// MARK: - Status model

/// What the rider needs to know, in plain words.
struct ConnectionStatus: Equatable {
    enum Tone { case waiting, working, good, warning, bad }
    let title: String
    let detail: String
    let symbol: String
    let tone: Tone

    var color: Color {
        switch tone {
        case .waiting: return Color(white: 0.6)
        case .working: return .orange
        case .good: return .green
        case .warning: return .yellow
        case .bad: return .red
        }
    }
}

extension SABClient {
    var status: ConnectionStatus {
        switch phase {
        case .idle:
            return .init(title: "Waiting for your scooter", detail: "Turn the ignition on", symbol: "key.horizontal.fill", tone: .waiting)
        case .scanning:
            return .init(title: "Looking for your scooter", detail: "Keep the phone close to the bike", symbol: "dot.radiowaves.left.and.right", tone: .working)
        case .connecting:
            return .init(title: "Connecting…", detail: connectedName ?? "Honda BTU", symbol: "link", tone: .working)
        case .securing, .assigning:
            return .init(title: "Pairing…", detail: "Setting up the handlebar buttons", symbol: "lock.shield.fill", tone: .working)
        case .ready where dashMode == .phone:
            return .init(title: "Ready to ride", detail: "Buttons control your music", symbol: "checkmark.circle.fill", tone: .good)
        case .ready:
            return .init(title: "Connected", detail: "Dash is on its own screen. Press Mute to switch", symbol: "rectangle.on.rectangle", tone: .warning)
        case .failed:
            return .init(title: "Something went wrong", detail: "Open Diagnostics for details", symbol: "exclamationmark.triangle.fill", tone: .bad)
        }
    }
}

// MARK: - Cards

private struct Card<Content: View>: View {
    @ViewBuilder var content: Content
    var body: some View {
        content
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(18)
            .background(.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 24, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 24, style: .continuous).strokeBorder(.white.opacity(0.08)))
    }
}

private struct HeroCard: View {
    @EnvironmentObject private var client: SABClient

    var body: some View {
        let status = client.status
        VStack(spacing: 18) {
            BikeImage()
                .frame(height: 220)
                .frame(maxWidth: .infinity)
                .clipped()
                .overlay(alignment: .bottom) {
                    LinearGradient(colors: [.clear, .black.opacity(0.55)], startPoint: .center, endPoint: .bottom)
                }
                .overlay(alignment: .bottomLeading) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("ScooterLink").font(.system(.title, design: .rounded).weight(.bold))
                        Text(client.connectedName ?? "Honda PCX").font(.subheadline).opacity(0.85)
                    }
                    .foregroundStyle(.white)
                    .padding(16)
                }
                .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
                .shadow(color: status.color.opacity(0.45), radius: 24, y: 8)

            HStack(spacing: 14) {
                ZStack {
                    Circle().fill(status.color.opacity(0.18)).frame(width: 52, height: 52)
                    Image(systemName: status.symbol)
                        .font(.title2.weight(.semibold))
                        .foregroundStyle(status.color)
                        .symbolEffect(.variableColor.iterative, isActive: status.tone == .working)
                        .contentTransition(.symbolEffect(.replace))
                }
                VStack(alignment: .leading, spacing: 3) {
                    Text(status.title).font(.headline)
                    Text(status.detail).font(.subheadline).foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
            }
            .animation(.smooth, value: status)

            if client.phase == .ready && client.dashMode != .phone {
                Button {
                    client.ensurePhoneScreen()
                } label: {
                    Label("Show phone screen on dash", systemImage: "iphone.gen3")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
            }
        }
        .padding(14)
        .background(.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 30, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 30, style: .continuous).strokeBorder(.white.opacity(0.08)))
    }
}

/// Your own bike photo if the asset catalog has a "Logo" image (not shipped in the repo),
/// otherwise a drawn placeholder.
private struct BikeImage: View {
    var body: some View {
        if let photo = UIImage(named: "Logo") {
            Image(uiImage: photo).resizable().aspectRatio(contentMode: .fill)
        } else {
            ZStack {
                LinearGradient(colors: [Color(white: 0.78), Color(white: 0.42)], startPoint: .topLeading, endPoint: .bottomTrailing)
                Image(systemName: "moped.fill")
                    .font(.system(size: 120, weight: .light))
                    .foregroundStyle(.white.opacity(0.9))
                    .shadow(color: .black.opacity(0.3), radius: 12, y: 6)
                    .offset(y: -16)
            }
        }
    }
}

private struct LastPressCard: View {
    @EnvironmentObject private var client: SABClient

    var body: some View {
        Card {
            HStack(spacing: 18) {
                let press = client.presses.first
                ZStack {
                    RoundedRectangle(cornerRadius: 20, style: .continuous)
                        .fill(LinearGradient(colors: [.orange, .red.opacity(0.85)], startPoint: .topLeading, endPoint: .bottomTrailing))
                        .frame(width: 76, height: 76)
                        .opacity(press == nil ? 0.25 : 1)
                    Image(systemName: press?.function?.symbol ?? "hand.tap.fill")
                        .font(.system(size: 32, weight: .semibold))
                        .foregroundStyle(.white)
                        .symbolEffect(.bounce, value: press?.id)
                        .contentTransition(.symbolEffect(.replace))
                }
                VStack(alignment: .leading, spacing: 4) {
                    Text("LAST BUTTON").font(.caption.weight(.semibold)).foregroundStyle(.secondary).tracking(1.2)
                    if let press, let function = press.function {
                        Text(function.label).font(.title3.weight(.semibold))
                        Text("\(function.action) · \(press.time, style: .relative) ago")
                            .font(.subheadline).foregroundStyle(.secondary)
                    } else {
                        Text("Press a handlebar button").font(.title3.weight(.semibold))
                        Text("It shows up here").font(.subheadline).foregroundStyle(.secondary)
                    }
                }
                Spacer(minLength: 0)
            }
            .animation(.snappy, value: client.presses.first?.id)
        }
    }
}

private struct ButtonMapCard: View {
    var body: some View {
        NavigationLink {
            ButtonSettingsView()
        } label: {
            Card {
                VStack(alignment: .leading, spacing: 14) {
                    HStack {
                        Text("BUTTONS").font(.caption.weight(.semibold)).foregroundStyle(.secondary).tracking(1.2)
                        Spacer()
                        Label("Customize", systemImage: "slider.horizontal.3")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.orange)
                    }
                    ForEach(ButtonSettings.configurable, id: \.rawValue) { function in
                        ButtonMapRow(function: function)
                    }
                }
            }
        }
        .buttonStyle(.plain)
    }
}

private struct Backdrop: View {
    let status: ConnectionStatus
    var body: some View {
        ZStack {
            LinearGradient(colors: [Color(red: 0.07, green: 0.08, blue: 0.11), .black], startPoint: .top, endPoint: .bottom)
            RadialGradient(colors: [status.color.opacity(0.22), .clear], center: .top, startRadius: 0, endRadius: 420)
                .animation(.smooth(duration: 0.8), value: status)
        }
        .ignoresSafeArea()
    }
}

extension ButtonFunction {
    /// What the button does in ScooterLink.
    var action: String {
        switch self {
        case .select, .back, .next, .previous, .menu:
            let action = ButtonSettings.action(for: self)
            return action == .nothing ? "—" : action.label
        case .volumeMute:
            let action = ButtonSettings.action(for: self)
            return action == .nothing ? "Phone screen" : action.label
        case .volumeUp, .volumeDown: return "—"
        case .modeSAB: return "Phone screen on"
        case .modeHU: return "Scooter screen on"
        }
    }
}
