import SwiftUI

struct LibraryView: View {
    @StateObject private var viewModel = LibraryViewModel()
    @State private var videoPendingDeletion: LibraryVideo?

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            addBar

            // A video that's already in the library sits in the list below, so suggesting it
            // here would only duplicate it — hide the banner in that case. (The backend already
            // filters these out; this guards against an older/stale backend doing otherwise.)
            if let suggestion = viewModel.suggestion, !suggestion.inLibrary {
                SuggestionBannerView(suggestion: suggestion, viewModel: viewModel)
            }

            if let errorMessage = viewModel.errorMessage {
                Label(errorMessage, systemImage: "exclamationmark.triangle")
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if viewModel.isLoading, viewModel.videos.isEmpty {
                Spacer()
                ProgressView("Loading Library")
                    .frame(maxWidth: .infinity)
                Spacer()
            } else if viewModel.videos.isEmpty {
                emptyState
            } else {
                // ScrollView + LazyVStack (not List) so the row cards sit flush at the
                // same leading inset as the header and the add bar — macOS List adds an
                // intrinsic horizontal inset that .contentMargins/.listRowInsets can't
                // fully remove. Delete still lives in the row's context menu and More menu.
                ScrollView {
                    LazyVStack(spacing: 12) {
                        ForEach(viewModel.videos) { video in
                            LibraryVideoRowView(video: video, viewModel: viewModel) {
                                videoPendingDeletion = video
                            }
                        }
                    }
                    .padding(.vertical, 4)
                }
                .scrollContentBackground(.hidden)
            }
        }
        .padding(32)
        .navigationTitle("Library")
        .confirmationDialog(
            "Delete this video?",
            isPresented: Binding(
                get: { videoPendingDeletion != nil },
                set: { if !$0 { videoPendingDeletion = nil } },
            ),
            titleVisibility: .visible,
            presenting: videoPendingDeletion,
        ) { video in
            Button("Delete", role: .destructive) {
                viewModel.deleteVideo(video)
            }
            Button("Cancel", role: .cancel) {}
        } message: { video in
            Text(
                "“\(video.displayTitle)” and its generated summary will be removed from your Library. This can't be undone.",
            )
        }
        .task {
            viewModel.startAutoRefresh()
        }
        .onDisappear {
            viewModel.stopAutoRefresh()
        }
    }

    private var addBar: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                Image(systemName: "link")
                    .foregroundStyle(.secondary)

                TextField("Paste a YouTube link…", text: $viewModel.urlInput)
                    .textFieldStyle(.plain)
                    .disableAutocorrection(true)
                    .onSubmit { viewModel.submitURL() }

                if !viewModel.urlInput.isEmpty {
                    Button {
                        viewModel.urlInput = ""
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                    .help("Clear")
                }

                Button {
                    viewModel.pasteFromClipboard()
                } label: {
                    Label("Paste", systemImage: "doc.on.clipboard")
                }
                .buttonStyle(.bordered)
                .disabled(viewModel.isSubmitting)
                .help("Paste a link from the clipboard and start processing")

                Button {
                    viewModel.submitURL()
                } label: {
                    if viewModel.isSubmitting {
                        ProgressView()
                            .controlSize(.small)
                    } else {
                        Label("Add", systemImage: "plus")
                    }
                }
                .buttonStyle(.borderedProminent)
                .disabled(!viewModel.canSubmitURL)
            }
            .padding(10)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8))

            if let notice = viewModel.noticeMessage {
                Label(notice, systemImage: "checkmark.circle.fill")
                    .font(.callout)
                    .foregroundStyle(.green)
            }

            if viewModel.showExtensionTip {
                extensionTip
            }
        }
    }

    /// Subtle one-line nudge under the add bar (populated library only).
    private var extensionTip: some View {
        HStack(spacing: 8) {
            Image(systemName: "puzzlepiece.extension")
                .foregroundStyle(.secondary)
            Text("Tip: send videos straight from a YouTube page with the browser extension.")
                .font(.callout)
                .foregroundStyle(.secondary)
            Link("Get it", destination: TubeFoldLinks.chromeWebStore)
                .font(.callout.weight(.semibold))
            Spacer(minLength: 0)
            Button {
                viewModel.dismissExtensionTip()
            } label: {
                Image(systemName: "xmark")
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .help("Dismiss")
        }
        .transition(.opacity)
    }

    private var emptyState: some View {
        VStack(spacing: 14) {
            Image(systemName: "play.rectangle")
                .font(.system(size: 42, weight: .regular))
                .foregroundStyle(.secondary)
            Text("No videos yet")
                .font(.title2.weight(.semibold))
            Text("Paste a YouTube link above, or send one from the Chrome extension, and it will appear here.")
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)

            if !viewModel.extensionConnected {
                Link(destination: TubeFoldLinks.chromeWebStore) {
                    Label("Get the Chrome extension", systemImage: "puzzlepiece.extension")
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .padding(.top, 4)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

#Preview {
    LibraryView()
        .frame(width: 720, height: 560)
}
