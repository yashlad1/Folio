import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// Batch conversion: pick files, pick a target, pick a folder, go.
///
/// Everything runs on this machine — see `OffscreenRenderer` for the guard
/// that keeps the rendering step from reaching the network — so the sheet has
/// no account, upload or progress-over-the-wire concepts in it.
struct ConvertSheet: View {
    @Environment(AppState.self) private var state
    @Environment(\.dismiss) private var dismiss

    @State private var sources: [URL]
    @State private var format: ConversionFormat
    @State private var destination: URL
    @State private var revealWhenDone = true

    @State private var isRunning = false
    @State private var progress = 0
    @State private var produced: [URL] = []
    @State private var failures: [Failure] = []
    @State private var hasRun = false

    struct Failure: Identifiable {
        let id = UUID()
        let name: String
        let reason: String
    }

    init(sources: [URL]) {
        let cleaned = sources.map(\.standardizedFileURL)
        _sources = State(initialValue: cleaned)
        _format = State(initialValue:
            ConversionFormat.available(forSources: cleaned.compactMap(SourceFamily.of)).first ?? .pdf
        )
        _destination = State(initialValue:
            cleaned.first?.deletingLastPathComponent()
                ?? FileManager.default.homeDirectoryForCurrentUser
        )
    }

    // MARK: Derived

    private var convertible: [URL] { sources.filter { SourceFamily.of($0) != nil } }
    private var unsupported: [URL] { sources.filter { SourceFamily.of($0) == nil } }
    private var formats: [ConversionFormat] {
        ConversionFormat.available(forSources: convertible.compactMap(SourceFamily.of))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Convert")
                .font(.title2.weight(.semibold))

            sourceSection
            Divider()
            optionsSection

            if hasRun || isRunning { resultSection }

            Spacer(minLength: 0)
            buttonRow
        }
        .padding(20)
        .frame(width: 520, height: 460)
    }

    // MARK: Sections

    private var sourceSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(sources.isEmpty
                     ? "No files chosen"
                     : "^[\(convertible.count) file](inflect: true) to convert")
                    .font(.callout.weight(.medium))
                Spacer()
                Button("Choose Files…", action: chooseSources)
            }

            if sources.isEmpty {
                Text("Pick markdown, text, Word, RTF, HTML, images, or PDFs.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 3) {
                        ForEach(sources, id: \.path) { url in
                            HStack(spacing: 6) {
                                Image(systemName: SourceFamily.of(url) == nil
                                      ? "exclamationmark.triangle" : "doc")
                                    .foregroundStyle(SourceFamily.of(url) == nil ? .orange : .secondary)
                                Text(url.lastPathComponent)
                                    .lineLimit(1)
                                    .truncationMode(.middle)
                            }
                            .font(.caption)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(height: 74)
            }

            if !unsupported.isEmpty {
                Text("^[\(unsupported.count) file](inflect: true) will be skipped — unsupported type.")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }
        }
    }

    private var optionsSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Picker("Convert to", selection: $format) {
                ForEach(formats) { Text($0.label).tag($0) }
            }
            .disabled(formats.isEmpty || isRunning)

            HStack(spacing: 8) {
                Text("Save to")
                Text(destination.lastPathComponent)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer()
                Button("Choose…", action: chooseDestination)
                    .disabled(isRunning)
            }

            Toggle("Reveal in Finder when finished", isOn: $revealWhenDone)
                .disabled(isRunning)
        }
    }

    @ViewBuilder
    private var resultSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Divider()
            if isRunning {
                ProgressView(value: Double(progress), total: Double(max(convertible.count, 1))) {
                    Text("Converting \(progress + 1) of \(convertible.count)…")
                        .font(.caption)
                }
            } else {
                Text("^[\(produced.count) file](inflect: true) written."
                     + (failures.isEmpty ? "" : " \(failures.count) failed."))
                    .font(.caption.weight(.medium))
                    .foregroundStyle(failures.isEmpty ? .green : .primary)
            }

            if !failures.isEmpty {
                ScrollView {
                    VStack(alignment: .leading, spacing: 4) {
                        ForEach(failures) { failure in
                            VStack(alignment: .leading, spacing: 1) {
                                Text(failure.name).font(.caption.weight(.medium))
                                Text(failure.reason)
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(height: 56)
            }
        }
    }

    private var buttonRow: some View {
        HStack {
            if isRunning { ProgressView().controlSize(.small) }
            Spacer()
            Button(hasRun && !isRunning ? "Done" : "Cancel") { dismiss() }
                .keyboardShortcut(.cancelAction)
            Button("Convert") { Task { await run() } }
                .keyboardShortcut(.defaultAction)
                .disabled(convertible.isEmpty || formats.isEmpty || isRunning)
        }
    }

    // MARK: Actions

    private func chooseSources() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.message = "Choose files to convert"
        panel.prompt = "Choose"
        guard panel.runModal() == .OK else { return }

        sources = panel.urls.map(\.standardizedFileURL)
        hasRun = false
        produced = []
        failures = []
        if let first = sources.first { destination = first.deletingLastPathComponent() }
        if !formats.contains(format), let fallback = formats.first { format = fallback }
    }

    private func chooseDestination() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.message = "Choose where to save the converted files"
        panel.prompt = "Choose"
        panel.directoryURL = destination
        guard panel.runModal() == .OK, let url = panel.url else { return }
        destination = url
    }

    @MainActor
    private func run() async {
        isRunning = true
        hasRun = true
        progress = 0
        produced = []
        failures = []

        for source in convertible {
            let target = Converter.vacantDestination(
                destination.appendingPathComponent(Converter.outputName(for: source, format: format))
            )
            do {
                try await Converter.convert(source, to: format, at: target)
                produced.append(target)
            } catch {
                failures.append(Failure(
                    name: source.lastPathComponent,
                    reason: error.localizedDescription
                ))
            }
            progress += 1
        }

        isRunning = false
        state.status = failures.isEmpty
            ? "Converted \(produced.count) to \(format.label)"
            : "Converted \(produced.count), \(failures.count) failed"

        if revealWhenDone, !produced.isEmpty {
            NSWorkspace.shared.activateFileViewerSelecting(produced)
        }
    }
}
