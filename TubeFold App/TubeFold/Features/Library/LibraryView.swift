import SwiftUI

struct LibraryView: View {
    @StateObject private var viewModel = LibraryViewModel()
    @ObservedObject private var appSettings = AppSettings.shared
    @State private var videoPendingDeletion: LibraryVideo?
    @FocusState private var urlFieldFocused: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// Rows and banners slide/scale a touch as they come and go; under Reduce
    /// Motion they simply cross-fade.
    private var cardTransition: AnyTransition {
        reduceMotion
            ? .opacity
            : .opacity.combined(with: .scale(scale: 0.97, anchor: .top))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            addBar

            // A video that's already in the library sits in the list below, so suggesting it
            // here would only duplicate it — hide the banner in that case. (The backend already
            // filters these out; this guards against an older/stale backend doing otherwise.)
            if appSettings.showWatchSuggestions, let suggestion = viewModel.suggestion, !suggestion.inLibrary {
                SuggestionBannerView(suggestion: suggestion, viewModel: viewModel)
                    .transition(cardTransition)
            }

            if let errorMessage = viewModel.errorMessage {
                Label(errorMessage, systemImage: "exclamationmark.triangle")
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
                    .transition(.opacity)
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
                            .transition(cardTransition)
                        }
                    }
                    .padding(.vertical, 4)
                }
                .scrollContentBackground(.hidden)
            }
        }
        .padding(32)
        // Library state changes come from background polling and optimistic
        // updates — animate them so rows and banners settle in instead of popping.
        .animation(.smooth(duration: 0.35), value: viewModel.videos)
        .animation(.smooth(duration: 0.3), value: viewModel.suggestion)
        .animation(.smooth(duration: 0.25), value: viewModel.errorMessage)
        .animation(.smooth(duration: 0.25), value: viewModel.noticeMessage)
        .animation(.smooth(duration: 0.25), value: viewModel.showExtensionTip)
        .navigationTitle("Library")
        .confirmationDialog(
            "Delete this video?",
            isPresented: Binding(
                get: { videoPendingDeletion != nil },
                set: {
                    if !$0 {
                        videoPendingDeletion = nil
                    }
                },
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
                    .foregroundStyle(urlFieldFocused ? Color.accentColor : Color.secondary)

                TextField("Paste a YouTube link…", text: $viewModel.urlInput)
                    .textFieldStyle(.plain)
                    .focused($urlFieldFocused)
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
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .strokeBorder(
                        urlFieldFocused ? Color.accentColor.opacity(0.5) : Color.primary.opacity(0.06),
                        lineWidth: 1,
                    ),
            )
            .animation(.smooth(duration: 0.2), value: urlFieldFocused)

            if let notice = viewModel.noticeMessage {
                Label(notice, systemImage: "checkmark.circle.fill")
                    .font(.callout)
                    .foregroundStyle(.green)
                    .transition(.opacity)
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
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(.secondary)
            Text("No videos yet")
                .font(.title2.weight(.semibold))
            Text("Paste a YouTube link above to create your first summary.")
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

#Preview {
    LibraryView()
        .frame(width: 720, height: 560)
}
