import SwiftUI
import HeadroomCore

/// Shown inside the panel, not as a sheet or a window. A sheet over a menu bar
/// panel outlives the panel: closing the panel left the sheet standing, "Done"
/// never reached it, and the next click on the icon showed Settings again.
struct SettingsView: View {
    @Bindable var model: AppModel
    let close: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Text("Settings").font(.system(size: 13, weight: .medium))
                Spacer()
                Button("Done", action: close)
                    .buttonStyle(.borderless)
                    .keyboardShortcut(.defaultAction)
            }

            VStack(alignment: .leading, spacing: 5) {
                Picker("Menu bar shows", selection: $model.menuBarMetric) {
                    ForEach(MenuBarMetric.allCases) { metric in
                        Text(metric.title).tag(metric)
                    }
                }
                .pickerStyle(.menu)
                .fixedSize()

                // The titles alone do not say which way the icon fills or what
                // counts as "room", and the difference decides whether a full
                // icon is good news or bad.
                Text(model.menuBarMetric.explanation)
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Toggle("Show the number next to the icon", isOn: $model.showsPercentInMenuBar)

            VStack(alignment: .leading, spacing: 4) {
                Text("Check every \(Int(model.intervalSeconds / 60)) min")
                Slider(value: $model.intervalSeconds, in: 180...1800, step: 60)
                Text("Anthropic rejects checks more often than every 3 minutes per account.")
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
            }
        }
        .padding(14)
    }
}
