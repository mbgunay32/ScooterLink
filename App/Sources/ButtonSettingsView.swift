import SwiftUI

/// Choose what each handlebar button does. Saved on the phone and used from the next press on.
struct ButtonSettingsView: View {
    @State private var confirmReset = false
    /// Bumped on reset so the rows re-read their saved values.
    @State private var generation = 0

    var body: some View {
        List {
            Section {
                ForEach(ButtonSettings.configurable, id: \.rawValue) { function in
                    ButtonActionRow(function: function)
                }
            } footer: {
                Text(L("Changes apply from the next press, no reconnect needed."))
            }
            .id(generation)

            Section {
                Label(L("Back / Forward 15 s and 30 s work in apps that offer jumps: podcasts, audiobooks, most video apps. Spotify offers them for podcasts, not for songs."),
                      systemImage: "info.circle")
                Label(L("Mute on the scooter's own screen always brings the phone screen back. Its action here runs only while the phone screen is showing."),
                      systemImage: "speaker.slash")
                Label(L("Menu may stay with the dash on some bikes. Check Diagnostics → Buttons to see whether it reaches the phone."),
                      systemImage: "line.3.horizontal")
            }
            .font(.footnote)
            .foregroundStyle(.secondary)

            Section {
                Button(L("Reset to defaults"), systemImage: "arrow.counterclockwise", role: .destructive) {
                    confirmReset = true
                }
            }
        }
        .navigationTitle(L("Buttons"))
        .navigationBarTitleDisplayMode(.inline)
        .confirmationDialog(L("Reset all buttons to their default actions?"), isPresented: $confirmReset, titleVisibility: .visible) {
            Button(L("Reset"), role: .destructive) {
                ButtonSettings.resetAll()
                generation += 1
            }
        }
    }
}

private struct ButtonActionRow: View {
    let function: ButtonFunction
    @AppStorage private var action: ButtonAction

    init(function: ButtonFunction) {
        self.function = function
        _action = AppStorage(wrappedValue: ButtonSettings.defaultAction(for: function), ButtonSettings.key(for: function))
    }

    var body: some View {
        Picker(selection: $action) {
            ForEach(ButtonAction.allCases) { option in
                Label(option.label, systemImage: option.symbol).tag(option)
            }
        } label: {
            Label {
                Text(function.label)
            } icon: {
                Image(systemName: function.symbol).foregroundStyle(.orange)
            }
        }
        .pickerStyle(.navigationLink)
    }
}

/// One line of the home screen's button map, kept in sync with the saved choice.
struct ButtonMapRow: View {
    let function: ButtonFunction
    @AppStorage private var action: ButtonAction

    init(function: ButtonFunction) {
        self.function = function
        _action = AppStorage(wrappedValue: ButtonSettings.defaultAction(for: function), ButtonSettings.key(for: function))
    }

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: function.symbol)
                .font(.body.weight(.semibold))
                .foregroundStyle(.orange)
                .frame(width: 36, height: 36)
                .background(.orange.opacity(0.15), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            Text(function.label).font(.body.weight(.medium)).foregroundStyle(.primary)
            Spacer()
            Text(summary).font(.subheadline).foregroundStyle(.secondary)
        }
    }

    private var summary: String {
        if function == .volumeMute {
            return action == .nothing ? L("Phone screen") : "\(action.label) · \(L("phone screen"))"
        }
        return action.label
    }
}
