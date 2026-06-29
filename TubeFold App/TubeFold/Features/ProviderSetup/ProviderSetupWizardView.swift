import SwiftUI
import UniformTypeIdentifiers

struct ProviderSetupWizardView: View {
    @ObservedObject var viewModel: ProviderSetupViewModel
    @Binding var isPresented: Bool
    @State private var showingExecutablePicker = false

    var body: some View {
        HStack(spacing: 0) {
            setupSidebar
                .frame(width: 235)
                .background(Color(nsColor: .windowBackgroundColor))

            Divider()

            VStack(alignment: .leading, spacing: 0) {
                HStack {
                    Button {
                        if viewModel.currentStep == .beforeBegin {
                            isPresented = false
                        } else {
                            viewModel.goBack()
                        }
                    } label: {
                        Label("Back", systemImage: "chevron.left")
                    }
                    .buttonStyle(.plain)

                    Spacer()
                }
                .padding(.bottom, 26)

                stepContent

                Spacer()

                VStack(alignment: .leading, spacing: 12) {
                    if let errorMessage = viewModel.errorMessage {
                        Label(errorMessage, systemImage: "exclamationmark.triangle.fill")
                            .font(.callout)
                            .foregroundStyle(.orange)
                            .fixedSize(horizontal: false, vertical: true)
                    }

                    HStack {
                        if viewModel.isBusy {
                            ProgressView()
                                .controlSize(.small)
                            Text(viewModel.busyMessage)
                                .foregroundStyle(.secondary)
                        }

                        Spacer()

                        Button {
                            Task {
                                if viewModel.currentStep == .complete {
                                    await viewModel.completeSetup()
                                    if viewModel.isSetupComplete {
                                        isPresented = false
                                    }
                                } else {
                                    await viewModel.advance()
                                }
                            }
                        } label: {
                            Label(viewModel.primaryButtonTitle, systemImage: viewModel.primaryButtonSystemImage)
                        }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.large)
                        .disabled(!viewModel.canAdvance || viewModel.isBusy)
                    }
                }
            }
            .padding(34)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
        .task {
            if !viewModel.hasLoadedState {
                await viewModel.loadState()
            }
        }
        .task(id: viewModel.currentStep) {
            await viewModel.prepareCurrentStepIfNeeded()
        }
        .fileImporter(
            isPresented: $showingExecutablePicker,
            allowedContentTypes: [.item],
            allowsMultipleSelection: false,
        ) { result in
            guard case let .success(urls) = result, let url = urls.first else { return }
            Task { await viewModel.detectInstallation(path: url.path) }
        }
    }

    private var setupSidebar: some View {
        VStack(alignment: .leading, spacing: 14) {
            ForEach(SetupStep.allCases) { step in
                StepRowView(
                    step: step,
                    isCurrent: viewModel.currentStep == step,
                    isComplete: viewModel.isStepComplete(step),
                )
            }
            Spacer()
        }
        .padding(28)
    }

    @ViewBuilder
    private var stepContent: some View {
        switch viewModel.currentStep {
        case .beforeBegin:
            StepIntroView(viewModel: viewModel)
        case .checkInstallation:
            StepInstallationView(
                viewModel: viewModel,
                showingExecutablePicker: $showingExecutablePicker,
            )
        case .testConnection:
            StepConnectionView(viewModel: viewModel)
        case .complete:
            StepCompleteView(viewModel: viewModel)
        }
    }
}

#Preview {
    ProviderSetupWizardView(viewModel: ProviderSetupViewModel(), isPresented: .constant(true))
        .frame(width: 820, height: 600)
}
