import SwiftUI

struct LibraryView: View {
    @StateObject private var viewModel = LibraryViewModel()

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            header

            if let errorMessage = viewModel.errorMessage {
                Label(errorMessage, systemImage: "exclamationmark.triangle")
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if viewModel.isLoading && viewModel.videos.isEmpty {
                Spacer()
                ProgressView("Loading Library")
                    .frame(maxWidth: .infinity)
                Spacer()
            } else if viewModel.videos.isEmpty {
                emptyState
            } else {
                ScrollView {
                    LazyVStack(spacing: 12) {
                        ForEach(viewModel.videos) { video in
                            LibraryVideoRow(video: video, viewModel: viewModel)
                        }
                    }
                    .padding(.bottom, 24)
                }
                .refreshable {
                    await viewModel.load()
                }
            }
        }
        .padding(32)
        .navigationTitle("Library")
        .task {
            await viewModel.load()
        }
    }

    private var header: some View {
        HStack(alignment: .center) {
            VStack(alignment: .leading, spacing: 8) {
                Text("Library")
                    .font(.largeTitle.weight(.semibold))
                Text("\(viewModel.videos.count) videos • \(viewModel.readyCount) ready • \(viewModel.activeCount) processing")
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button {
                Task { await viewModel.load() }
            } label: {
                Label(viewModel.isLoading ? "Refreshing" : "Refresh", systemImage: "arrow.clockwise")
            }
            .buttonStyle(.bordered)
            .controlSize(.large)
            .disabled(viewModel.isLoading)
        }
    }

    private var emptyState: some View {
        VStack(spacing: 14) {
            Image(systemName: "play.rectangle")
                .font(.system(size: 42, weight: .regular))
                .foregroundStyle(.secondary)
            Text("No videos yet")
                .font(.title2.weight(.semibold))
            Text("Send a YouTube video from the Chrome extension and it will appear here.")
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

struct LibraryVideoRow: View {
    let video: LibraryVideo
    @ObservedObject var viewModel: LibraryViewModel

    var body: some View {
        HStack(alignment: .top, spacing: 16) {
            thumbnail

            VStack(alignment: .leading, spacing: 10) {
                HStack(alignment: .top, spacing: 12) {
                    VStack(alignment: .leading, spacing: 5) {
                        Text(video.displayTitle)
                            .font(.headline)
                            .lineLimit(2)
                        Text(video.displayChannel)
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }

                    Spacer()

                    StatusBadge(status: video.status)
                }

                HStack(spacing: 14) {
                    MetadataLabel(systemImage: "clock", text: formatDuration(video.durationSeconds))
                    MetadataLabel(systemImage: "calendar", text: formatDate(video.updatedAt))
                    if let latestJobID = video.latestJobID {
                        MetadataLabel(systemImage: "number", text: String(latestJobID.prefix(8)))
                    }
                }

                if video.status == "failed" {
                    Text(video.errorMessage ?? "Summary failed.")
                        .font(.callout)
                        .foregroundStyle(.orange)
                        .lineLimit(2)
                }

                HStack(spacing: 8) {
                    if video.status == "failed" {
                        Button {
                            viewModel.regenerate(video)
                        } label: {
                            Label("Retry", systemImage: "arrow.clockwise")
                        }
                    }

                    Button {
                        viewModel.openYouTube(video)
                    } label: {
                        Label("YouTube", systemImage: "play.rectangle")
                    }

                    Button {
                        viewModel.openMarkdown(video)
                    } label: {
                        Label("Summary", systemImage: "doc.text")
                    }
                    .disabled(!video.hasMarkdown)

                    Button {
                        viewModel.revealMarkdown(video)
                    } label: {
                        Label("Show File", systemImage: "folder")
                    }
                    .disabled(!video.hasMarkdown)

                    Button {
                        viewModel.saveMarkdownCopy(video)
                    } label: {
                        Label("Save Markdown", systemImage: "square.and.arrow.down")
                    }
                    .disabled(!video.hasMarkdown)
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8))
    }

    @ViewBuilder
    private var thumbnail: some View {
        if let url = video.thumbnailImageURL {
            AsyncImage(url: url) { phase in
                switch phase {
                case .success(let image):
                    image
                        .resizable()
                        .scaledToFill()
                default:
                    thumbnailPlaceholder
                }
            }
            .frame(width: 148, height: 84)
            .clipShape(RoundedRectangle(cornerRadius: 6))
        } else {
            thumbnailPlaceholder
                .frame(width: 148, height: 84)
        }
    }

    private var thumbnailPlaceholder: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 6)
                .fill(Color.secondary.opacity(0.12))
            Image(systemName: "play.rectangle")
                .font(.title2)
                .foregroundStyle(.secondary)
        }
    }
}

struct StatusBadge: View {
    let status: String

    var body: some View {
        Label(statusTitle, systemImage: statusIcon)
            .font(.caption.weight(.semibold))
            .foregroundStyle(statusColor)
            .padding(.vertical, 5)
            .padding(.horizontal, 9)
            .background(statusColor.opacity(0.12), in: Capsule())
    }

    private var statusTitle: String {
        switch status {
        case "queued":
            return "Queued"
        case "fetchingMetadata":
            return "Metadata"
        case "fetchingTranscript":
            return "Transcript"
        case "generatingSummary":
            return "Summarizing"
        case "ready":
            return "Ready"
        case "failed":
            return "Failed"
        case "cancelled":
            return "Cancelled"
        default:
            return status
        }
    }

    private var statusIcon: String {
        switch status {
        case "ready":
            return "checkmark.circle.fill"
        case "failed", "cancelled":
            return "exclamationmark.triangle.fill"
        case "queued":
            return "clock.fill"
        default:
            return "arrow.triangle.2.circlepath"
        }
    }

    private var statusColor: Color {
        switch status {
        case "ready":
            return .green
        case "failed", "cancelled":
            return .orange
        case "queued":
            return .secondary
        default:
            return .blue
        }
    }
}

struct MetadataLabel: View {
    let systemImage: String
    let text: String

    var body: some View {
        Label(text, systemImage: systemImage)
            .font(.caption)
            .foregroundStyle(.secondary)
            .lineLimit(1)
    }
}

private func formatDuration(_ seconds: Double?) -> String {
    guard let seconds, seconds > 0 else { return "Unknown length" }
    let total = Int(seconds.rounded())
    let minutes = total / 60
    let remainingSeconds = total % 60
    if minutes >= 60 {
        return "\(minutes / 60)h \(minutes % 60)m"
    }
    return "\(minutes):\(String(format: "%02d", remainingSeconds))"
}

private func formatDate(_ value: String) -> String {
    let formatter = ISO8601DateFormatter()
    guard let date = formatter.date(from: value) else { return value }
    return date.formatted(date: .abbreviated, time: .shortened)
}
