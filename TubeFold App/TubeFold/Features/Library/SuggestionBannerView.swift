import SwiftUI

struct SuggestionBannerView: View {
    let suggestion: WatchSuggestion
    @ObservedObject var viewModel: LibraryViewModel

    var body: some View {
        HStack(alignment: .center, spacing: 14) {
            thumbnail

            VStack(alignment: .leading, spacing: 4) {
                Text("Recently watched")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                Text(suggestion.displayTitle)
                    .font(.headline)
                    .lineLimit(1)
                Text(suggestion.displayChannel)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            if suggestion.inLibrary {
                if let status = suggestion.libraryStatus {
                    StatusBadgeView(status: status)
                }
                Button {
                    viewModel.openSuggestion()
                } label: {
                    Label("Open", systemImage: "arrow.up.forward.app")
                }
                .buttonStyle(.bordered)
            } else {
                Button {
                    viewModel.acceptSuggestion()
                } label: {
                    if viewModel.isSubmitting {
                        ProgressView().controlSize(.small)
                    } else {
                        Label("Generate", systemImage: "sparkles")
                    }
                }
                .buttonStyle(.borderedProminent)
                .disabled(viewModel.isSubmitting)
            }

            Button {
                viewModel.dismissSuggestion()
            } label: {
                Image(systemName: "xmark")
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .help("Dismiss")
        }
        .padding(12)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8))
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .strokeBorder(Color.accentColor.opacity(0.35), lineWidth: 1),
        )
    }

    @ViewBuilder
    private var thumbnail: some View {
        if let url = suggestion.thumbnailImageURL {
            AsyncImage(url: url) { phase in
                switch phase {
                case let .success(image):
                    image.resizable().scaledToFill()
                default:
                    Color.secondary.opacity(0.12)
                }
            }
            .frame(width: 96, height: 54)
            .clipShape(RoundedRectangle(cornerRadius: 6))
        } else {
            RoundedRectangle(cornerRadius: 6)
                .fill(Color.secondary.opacity(0.12))
                .frame(width: 96, height: 54)
        }
    }
}

extension WatchSuggestion {
    static let preview = WatchSuggestion(
        youtubeVideoID: "dQw4w9WgXcQ",
        canonicalURL: "https://youtu.be/dQw4w9WgXcQ",
        title: "How transformers actually work",
        channelName: "Deep Dive",
        thumbnailURL: nil,
        durationSeconds: 942,
        watchedAt: "2026-06-29T10:00:00Z",
        inLibrary: false,
        libraryVideoID: nil,
        libraryStatus: nil,
    )
}

#Preview {
    SuggestionBannerView(suggestion: .preview, viewModel: LibraryViewModel())
        .padding()
        .frame(width: 640)
}
