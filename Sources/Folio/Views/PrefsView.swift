import SwiftUI

struct PrefsView: View {
    @State private var prefs = Prefs.shared
    @State private var recents = Recents.shared

    var body: some View {
        Form {
            Section("Appearance") {
                Picker("Theme", selection: $prefs.theme) {
                    ForEach(AppTheme.allCases) { Text($0.label).tag($0) }
                }
                .pickerStyle(.segmented)
            }

            Section("Markdown") {
                Picker("Typeface", selection: $prefs.readingFont) {
                    ForEach(ReadingFont.allCases) { Text($0.label).tag($0) }
                }
                .pickerStyle(.segmented)

                HStack {
                    Text("Text size")
                    Slider(value: $prefs.fontSize, in: 11...30, step: 1)
                    Text("\(Int(prefs.fontSize)) pt")
                        .monospacedDigit()
                        .frame(width: 44, alignment: .trailing)
                }

                Toggle("Use the full window width", isOn: $prefs.wideContent)
                Toggle("Show line numbers in code blocks", isOn: $prefs.codeLineNumbers)
            }

            Section("PDF") {
                Toggle("Open in two-page view", isOn: $prefs.twoUp)
                Text("Folio remembers the last page of every PDF you open.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Recents") {
                HStack {
                    Text("\(recents.items.count) remembered")
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button("Clear Recents") { recents.clear() }
                }
            }
        }
        .formStyle(.grouped)
        .frame(width: 460, height: 470)
    }
}
