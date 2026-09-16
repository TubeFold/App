import SwiftUI
import TubeFoldKit

/// Sheet shown when a channel URL is added to the Library: pick which tabs to
/// dump, where, then watch the transcripts land one by one.
struct ChannelExportSheetView: View {
    // Owned here (not by the presenting view) so the running export survives
    // re-renders of the sheet content; the view model is created once per request.
    @StateObject private var viewModel: ChannelExportViewModel
    @Binding var isPresented: Bool

    init(request: ChannelExportRequest, isPresented: Binding<Bool>) {
        _viewModel = StateObject(wrappedValue: ChannelExportViewModel(reference: request.reference))
        _isPresented = isPresented
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            header

            switch viewModel.phase {
            case .configuring:
                optionsForm
            case .listing, .exporting:
                progress
            case let .finished(result):
                summary(result)
            case let .failed(message):
                failure(message)
            }

            Spacer(minLength: 0)

            footer
        }
        .padding(28)
        .frame(width: 520)
        .frame(minHeight: 380)
        .animation(.smooth(duration: 0.25), value: viewModel.phase)
        .interactiveDismissDisabled(viewModel.isRunning)
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Export Channel Transcripts")
                .font(.title2.weight(.semibold))
            Text(viewModel.reference.label)
                .font(.callout)
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
        }
    }

    // MARK: - Configuring

    private var optionsForm: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("Every video's transcript is saved as its own Markdown file, publish date first, into one folder for the channel. No summaries are generated and nothing is added to your Library.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            VStack(alignment: .leading, spacing: 8) {
                Text("Include")
                    .font(.subheadline.weight(.semibold))
                HStack(spacing: 18) {
                    Toggle("Videos", isOn: $viewModel.includeVideos)
                    Toggle("Shorts", isOn: $viewModel.includeShorts)
                    Toggle("Live streams", isOn: $viewModel.includeStreams)
                }
                .toggleStyle(.checkbox)
            }

            VStack(alignment: .leading, spacing: 8) {
                Text("How many")
                    .font(.subheadline.weight(.semibold))
                HStack(spacing: 12) {
                    Picker("", selection: $viewModel.limitToNewest) {
                        Text("All videos").tag(false)
                        Text("Newest only").tag(true)
                    }
                    .labelsHidden()
                    .pickerStyle(.radioGroup)
                    .horizontalRadioGroupLayout()

                    if viewModel.limitToNewest {
                        TextField("", value: $viewModel.newestCount, format: .number)
                            .labelsHidden()
                            .textFieldStyle(.roundedBorder)
                            .frame(width: 64)
                        Stepper("", value: $viewModel.newestCount, in: 1 ... 10000)
                            .labelsHidden()
                    }
                }
            }

            VStack(alignment: .leading, spacing: 8) {
                Text("Save to")
                    .font(.subheadline.weight(.semibold))
                HStack(spacing: 10) {
                    Image(systemName: "folder")
                        .foregroundStyle(.secondary)
                    Text(viewModel.destination.path(percentEncoded: false))
                        .font(.callout)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .help(viewModel.destination.path(percentEncoded: false))
                    Spacer(minLength: 0)
                    Button("Choose…") {
                        viewModel.chooseDestination()
                    }
                }
                .padding(10)
                .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            }

            Toggle("Skip videos already exported to this folder", isOn: $viewModel.skipExisting)
                .toggleStyle(.checkbox)
        }
    }

    // MARK: - Running

    private var progress: some View {
        VStack(alignment: .leading, spacing: 12) {
            switch viewModel.phase {
            case .listing:
                ProgressView()
                    .progressViewStyle(.linear)
                Text("Listing channel videos…")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            case let .exporting(done, total, current):
                ProgressView(value: Double(done), total: Double(max(total, 1)))
                    .progressViewStyle(.linear)
                HStack {
                    Text("\(done) of \(total)")
                        .font(.callout.monospacedDigit())
                        .foregroundStyle(.secondary)
                    Spacer()
                }
                if !current.isEmpty {
                    Text(current)
                        .font(.callout)
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                }
            default:
                EmptyView()
            }
        }
        .padding(.top, 8)
    }

    // MARK: - Finished

    private func summary(_ result: ChannelExportViewModel.ChannelExportResult) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            Label(
                result.cancelled ? "Export stopped." : "Export complete.",
                systemImage: result.cancelled ? "stop.circle.fill" : "checkmark.circle.fill",
            )
            .font(.headline)
            .foregroundStyle(result.cancelled ? Color.secondary : Color.green)

            Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 6) {
                GridRow {
                    Text("Saved").foregroundStyle(.secondary)
                    Text("\(result.saved)").monospacedDigit()
                }
                if result.skipped > 0 {
                    GridRow {
                        Text("Already exported").foregroundStyle(.secondary)
                        Text("\(result.skipped)").monospacedDigit()
                    }
                }
                if result.noCaptions > 0 {
                    GridRow {
                        Text("No captions on YouTube").foregroundStyle(.secondary)
                        Text("\(result.noCaptions)").monospacedDigit()
                    }
                }
                if result.failed > 0 {
                    GridRow {
                        Text("Failed").foregroundStyle(.secondary)
                        Text("\(result.failed)")
                            .monospacedDigit()
                            .foregroundStyle(.red)
                    }
                }
            }
            .font(.callout)

            if result.noCaptions > 0 {
                Text("Videos without captions have no transcript to export — YouTube never generated one for them (common for older uploads).")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            HStack(spacing: 8) {
                Image(systemName: "folder")
                    .foregroundStyle(.secondary)
                Text(result.folder.path(percentEncoded: false))
                    .font(.callout)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .textSelection(.enabled)
            }

            if result.failed > 0 {
                Text("Details for failed videos are in index.md inside the folder.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func failure(_ message: String) -> some View {
        Label(message, systemImage: "exclamationmark.triangle.fill")
            .font(.callout)
            .foregroundStyle(.red)
            .fixedSize(horizontal: false, vertical: true)
    }

    // MARK: - Footer

    private var footer: some View {
        HStack {
            Spacer()
            switch viewModel.phase {
            case .configuring:
                Button("Cancel") {
                    isPresented = false
                }
                .keyboardShortcut(.cancelAction)
                Button("Export") {
                    viewModel.start()
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
                .disabled(!viewModel.canStart)
            case .listing, .exporting:
                Button("Stop") {
                    viewModel.cancel()
                }
                .keyboardShortcut(.cancelAction)
            case .finished:
                Button("Show in Finder") {
                    viewModel.revealFolder()
                }
                Button("Done") {
                    isPresented = false
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
            case .failed:
                Button("Close") {
                    isPresented = false
                }
                .keyboardShortcut(.cancelAction)
                Button("Try Again") {
                    viewModel.retry()
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
            }
        }
    }
}
