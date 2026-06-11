import SwiftUI
import AmbitickCore
import AmbitickMac

struct SettingsView: View {
    @ObservedObject var controller: AppController
    @State private var apiKey = ""
    @State private var keySaved = false

    var body: some View {
        Form {
            Section("OpenProject") {
                TextField("Instance URL", text: $controller.settings.opBaseURL,
                          prompt: Text("https://op.example.com"))
                SecureField("API key", text: $apiKey)
                HStack {
                    Button("Save key & connect") {
                        controller.saveAPIKey(apiKey)
                        apiKey = ""
                        keySaved = true
                    }
                    .disabled(apiKey.isEmpty || controller.settings.opBaseURL.isEmpty)
                    if keySaved { Text("Saved to Keychain").font(.caption).foregroundStyle(.secondary) }
                }
                if let error = controller.lastError {
                    Text(error).font(.caption).foregroundStyle(.red)
                } else {
                    Text(controller.taskCache.isEmpty
                         ? "Not connected yet"
                         : "Connected – \(controller.taskCache.count) tasks loaded")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Picker("Default activity",
                       selection: Binding(
                        get: { controller.settings.defaultActivityID ?? -1 },
                        set: { controller.settings.defaultActivityID = $0 == -1 ? nil : $0 })) {
                    Text("–").tag(-1)
                    ForEach(controller.activities, id: \.id) { a in
                        Text(a.name).tag(a.id)
                    }
                }
            }

            Section("Auto-push") {
                let threshold = controller.settings.certaintyAutoPushThreshold
                Slider(value: $controller.settings.certaintyAutoPushThreshold, in: 0.5...1.01)
                Text(threshold > 1.0 ? "Never auto-push (review everything)"
                     : "Auto-push sessions ≥ \(Int((threshold * 100).rounded()))% certain")
                    .font(.caption).foregroundStyle(.secondary)
                Toggle("Auto-comment time entries (apps/docs used)",
                       isOn: $controller.settings.autoComment)
                Text(controller.journalSummary)
                    .font(.caption).foregroundStyle(.secondary)
            }

            Section("Menu bar") {
                TextField("Low-certainty colour (hex)", text: $controller.settings.colourLow)
                TextField("High-certainty colour (hex)", text: $controller.settings.colourHigh)
                Text("Set both to the same colour to disable the signalling.")
                    .font(.caption).foregroundStyle(.secondary)
                Toggle("Show certainty %", isOn: $controller.settings.showPercent)
            }

            Section("Behaviour") {
                Toggle("Track leisure to local-only tasks (instead of stopping)",
                       isOn: $controller.settings.trackLeisureLocally)
                Stepper("Recent tasks shown: \(controller.settings.recentCount)",
                        value: $controller.settings.recentCount, in: 1...15)
                Stepper("Likely tasks shown: \(controller.settings.likelyCount)",
                        value: $controller.settings.likelyCount, in: 1...15)
            }

        }
        .formStyle(.grouped)
        .padding(8)
    }
}
