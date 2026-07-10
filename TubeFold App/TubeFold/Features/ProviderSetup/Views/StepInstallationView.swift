import AppKit
import SwiftUI

struct StepInstallationView: View {
    @ObservedObject var viewModel: ProviderSetupViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            Text("Check Installation")
                .font(.largeTitle.weight(.semibold))
            Text("We look for \(viewModel.providerDisplayName) and verify the executable with a version check.")
                .foregroundStyle(.secondary)

            ProviderResultCardView(
                title: viewModel.providerDisplayName,
                status: viewModel.installationStatusTitle,
                message: viewModel.installationMessage,
                systemImage: viewModel.installationSucceeded ? "checkmark.circle.fill" : "terminal",
                tint: viewModel.installationSucceeded ? .green : .orange,
            )

            if viewModel.shouldShowCodexCLIInstallHelp {
                CodexCLIInstallHelpView(
                    chatGPTAppInstalled: viewModel.chatGPTAppInstalled,
                    chatGPTAppPath: viewModel.chatGPTAppPath,
                    appInstalled: viewModel.codexAppInstalled,
                    appPath: viewModel.codexAppPath,
                )
            }

            HStack {
                Button {
                    Task { await viewModel.detectInstallation(path: nil) }
                } label: {
                    Label("Re-check", systemImage: "arrow.clockwise")
                }
                .disabled(viewModel.isBusy)
            }

            DetailsView(
                details: viewModel.installationDetails,
                showsCopyButton: viewModel.installationHasError,
            )
        }
        .frame(maxWidth: 600, alignment: .leading)
    }
}

private struct CodexCLIInstallHelpView: View {
    let chatGPTAppInstalled: Bool
    let chatGPTAppPath: String?
    let appInstalled: Bool
    let appPath: String?
    @State private var copied = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("Install Codex CLI in Terminal", systemImage: "terminal")
                .font(.headline)

            Text(helpMessage)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            Text(ProviderSetupViewModel.codexCLIInstallCommand)
                .font(.system(.callout, design: .monospaced))
                .textSelection(.enabled)
                .padding(10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(.background.opacity(0.55), in: RoundedRectangle(cornerRadius: 6))

            HStack(spacing: 10) {
                Button {
                    copyInstallCommand()
                } label: {
                    Label(copied ? "Copied" : "Copy install command", systemImage: copied ? "checkmark" : "doc.on.doc")
                }

                Link(destination: ProviderSetupViewModel.codexCLIInstallGuideURL) {
                    Label("Open install guide", systemImage: "arrow.up.right.square")
                }
            }
            .controlSize(.small)

            Text("After installing, open a new Terminal, run `codex` once to sign in, then return here and re-check.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(16)
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    private var helpMessage: String {
        if chatGPTAppInstalled {
            return installedChatGPTAppMessage
        }
        if appInstalled {
            return installedCodexAppMessage
        }
        return missingCLIMessage
    }

    private var installedChatGPTAppMessage: String {
        if let chatGPTAppPath, !chatGPTAppPath.isEmpty {
            return "The ChatGPT macOS app is installed at \(chatGPTAppPath), but TubeFold cannot use it directly. Install Codex CLI to connect TubeFold to your ChatGPT account."
        }
        return "The ChatGPT macOS app is installed, but TubeFold cannot use it directly. Install Codex CLI to connect TubeFold to your ChatGPT account."
    }

    private var installedCodexAppMessage: String {
        if let appPath, !appPath.isEmpty {
            return "The Codex macOS app is installed at \(appPath), but TubeFold needs the separate `codex` command-line tool."
        }
        return "The Codex macOS app is installed, but TubeFold needs the separate `codex` command-line tool."
    }

    private var missingCLIMessage: String {
        "TubeFold uses the `codex` command-line tool to generate summaries. The macOS app does not install this executable."
    }

    private func copyInstallCommand() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(ProviderSetupViewModel.codexCLIInstallCommand, forType: .string)
        copied = true
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(1.5))
            copied = false
        }
    }
}

#Preview {
    StepInstallationView(viewModel: ProviderSetupViewModel())
        .padding(34)
        .frame(width: 660, height: 480)
}
