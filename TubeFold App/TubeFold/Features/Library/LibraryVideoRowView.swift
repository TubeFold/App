import SwiftUI

struct LibraryVideoRowView: View {
    let video: LibraryVideo
    @ObservedObject var viewModel: LibraryViewModel
    let onDelete: () -> Void

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

                    StatusBadgeView(status: video.status)
                }

                HStack(spacing: 14) {
                    MetadataLabelView(systemImage: "clock", text: formatDuration(video.durationSeconds))
                    if let readingTimeText = video.readingTimeText {
                        MetadataLabelView(systemImage: "book", text: readingTimeText)
                    }
                    MetadataLabelView(systemImage: "calendar", text: formatDate(video.updatedAt))
                }

                if video.status == "failed" {
                    Text(video.errorMessage ?? "Summary failed.")
                        .font(.callout)
                        .foregroundStyle(.red)
                        .fixedSize(horizontal: false, vertical: true)
                }

                HStack(spacing: 8) {
                    if video.status == "failed" {
                        RowMiniButtonView("Retry", systemImage: "arrow.clockwise") {
                            viewModel.regenerate(video)
                        }

                        if video.hasJobLogs {
                            RowMiniButtonView("Show Logs", systemImage: "doc.text.magnifyingglass") {
                                viewModel.revealLogs(video)
                            }
                        }
                    }

                    // Only surface Telegraph once the summary is ready — while a job is
                    // still running there's nothing to publish, so the button stays hidden
                    // and fades in when the summary lands instead of sitting there disabled.
                    if video.hasMarkdown {
                        RowMiniButtonView {
                            viewModel.publishToTelegraph(video)
                        } label: {
                            if viewModel.isPublishing(video) {
                                Label("Publishing…", systemImage: "paperplane")
                            } else if video.isPublishedToTelegraph {
                                Label("Open Telegraph", systemImage: "paperplane.fill")
                            } else {
                                Label("Read in Telegraph", systemImage: "paperplane")
                            }
                        }
                        .disabled(viewModel.isPublishing(video))
                        .transition(.opacity.combined(with: .move(edge: .leading)))

                        RowMiniButtonView {
                            viewModel.openPDF(video)
                        } label: {
                            if viewModel.isRenderingPDF(video) {
                                Label("Opening…", systemImage: "doc.richtext")
                            } else {
                                Label("Open PDF", systemImage: "doc.richtext")
                            }
                        }
                        .disabled(viewModel.isRenderingPDF(video))
                        .transition(.opacity.combined(with: .move(edge: .leading)))

                        RowMiniButtonView("Open Markdown", systemImage: "doc.plaintext") {
                            viewModel.openMarkdown(video)
                        }
                        .transition(.opacity.combined(with: .move(edge: .leading)))
                    }

                    RowMiniButtonView("YouTube", systemImage: "play.rectangle") {
                        viewModel.openYouTube(video)
                    }

                    RowMiniMenuView("More", systemImage: "ellipsis") {
                        moreMenuItems
                    }
                }
                .animation(.smooth(duration: 0.3), value: video.hasMarkdown)
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.06), lineWidth: 1),
        )
        .contextMenu {
            moreMenuItems
        }
    }

    @ViewBuilder
    private var moreMenuItems: some View {
        Button {
            viewModel.revealMarkdown(video)
        } label: {
            Label("Show Files", systemImage: "folder")
        }
        .disabled(!video.hasMarkdown)

        if video.hasJobLogs {
            Button {
                viewModel.revealLogs(video)
            } label: {
                Label("Show Logs", systemImage: "doc.text.magnifyingglass")
            }
        }

        Divider()

        Button(role: .destructive) {
            onDelete()
        } label: {
            Label("Delete", systemImage: "trash")
        }
    }

    @ViewBuilder
    private var thumbnail: some View {
        if let url = video.thumbnailImageURL {
            // The transaction fades the loaded image in over the placeholder
            // instead of swapping it in on whatever frame the download lands.
            AsyncImage(url: url, transaction: Transaction(animation: .smooth(duration: 0.3))) { phase in
                switch phase {
                case let .success(image):
                    image
                        .resizable()
                        .scaledToFill()
                        .transition(.opacity)
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

private func formatDuration(_ seconds: Double?) -> String {
    guard let seconds, seconds > 0 else { return "Unknown length" }
    let total = Int(seconds.rounded())
    let minutes = max(1, (total + 59) / 60)
    if minutes >= 60 {
        let hours = minutes / 60
        let remainingMinutes = minutes % 60
        if remainingMinutes == 0 {
            return "\(hours) hr watch"
        }
        return "\(hours) hr \(remainingMinutes) min watch"
    }
    return "\(minutes) min watch"
}

private func formatDate(_ value: String) -> String {
    let formatter = ISO8601DateFormatter()
    guard let date = formatter.date(from: value) else { return value }
    return date.formatted(date: .abbreviated, time: .shortened)
}

extension LibraryVideo {
    static let preview = LibraryVideo(
        id: "video-1",
        youtubeVideoID: "dQw4w9WgXcQ",
        canonicalURL: "https://youtu.be/dQw4w9WgXcQ",
        title: "How transformers actually work",
        channelName: "Deep Dive",
        thumbnailURL: nil,
        durationSeconds: 942,
        currentTimeAtRequest: nil,
        createdAt: "2026-06-29T10:00:00Z",
        updatedAt: "2026-06-29T10:05:00Z",
        status: "ready",
        transcriptPath: "/tmp/transcript.txt",
        summaryPath: "/tmp/summary.md",
        errorCode: nil,
        errorMessage: nil,
        latestJobID: "job-1",
        latestJobStatus: "ready",
        latestJobCreatedAt: "2026-06-29T10:00:00Z",
        latestJobFinishedAt: "2026-06-29T10:05:00Z",
        telegraphURL: nil,
        readingTimeMinutes: 4,
        jobLogPath: nil,
    )
}

#Preview {
    LibraryVideoRowView(video: .preview, viewModel: LibraryViewModel(), onDelete: {})
        .padding()
        .frame(width: 720)
}
