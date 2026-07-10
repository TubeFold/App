import SwiftUI

struct ProviderSetupWizardView: View {
    @ObservedObject var viewModel: ProviderSetupViewModel
    @Binding var isPresented: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// Steps materialize in place (blur + scale) rather than hard-cutting;
    /// Reduce Motion gets a plain cross-fade.
    private var stepTransition: AnyTransition {
        reduceMotion ? .opacity : AnyTransition(.blurReplace)
    }

    var body: some View {
        HStack(spacing: 0) {
            setupSidebar
                .frame(width: 235)
                .background(Color(nsColor: .windowBackgroundColor))

            Divider()

            VStack(alignment: .leading, spacing: 0) {
                HStack {
                    if viewModel.currentStep != .welcome {
                        Button {
                            viewModel.goBack()
                        } label: {
                            Label("Back", systemImage: "chevron.left")
                        }
                        .buttonStyle(.plain)
                    }

                    Spacer()

                    Button {
                        isPresented = false
                    } label: {
                        Image(systemName: "xmark")
                            .font(.system(size: 13, weight: .semibold))
                            .frame(width: 28, height: 28)
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
                    .help("Close setup")
                    .accessibilityLabel("Close setup")
                    .keyboardShortcut(.cancelAction)
                }
                .padding(.bottom, 26)

                stepContent
                    .transition(stepTransition)

                Spacer()

                VStack(alignment: .leading, spacing: 12) {
                    if let errorMessage = viewModel.errorMessage {
                        Label(errorMessage, systemImage: "exclamationmark.triangle.fill")
                            .font(.callout)
                            .foregroundStyle(.red)
                            .fixedSize(horizontal: false, vertical: true)
                            .transition(.opacity)
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
        // Step changes come from async view-model work, so the animation is
        // bound to the values here instead of withAnimation at the call sites.
        .animation(.smooth(duration: 0.35), value: viewModel.currentStep)
        .animation(.smooth(duration: 0.25), value: viewModel.isBusy)
        .animation(.smooth(duration: 0.25), value: viewModel.errorMessage)
        .task {
            if !viewModel.hasLoadedState {
                await viewModel.loadState()
            }
        }
        .task(id: viewModel.currentStep) {
            await viewModel.prepareCurrentStepIfNeeded()
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
        case .welcome:
            StepWelcomeView()
        case .outputLanguage:
            StepOutputLanguageView(viewModel: viewModel)
        case .beforeBegin:
            StepIntroView(viewModel: viewModel)
        case .checkInstallation:
            StepInstallationView(viewModel: viewModel)
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
