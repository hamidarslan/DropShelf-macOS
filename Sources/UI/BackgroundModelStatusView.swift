import SwiftUI

public struct BackgroundModelStatusView: View {
    @ObservedObject private var store: BackgroundModelStore
    @ObservedObject private var operation = OperationCoordinator.shared
    private let allowsRemoval: Bool
    @State private var message = ""
    private static let installTitle = "Install background-removal model"
    private static let removeTitle = "Remove background-removal model"

    public init(store: BackgroundModelStore = .shared, allowsRemoval: Bool = false) {
        self.store = store
        self.allowsRemoval = allowsRemoval
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            Text("Quality background removal").font(.system(size: 12, weight: .semibold))
            Text("Optional BiRefNet model. Download once, then use it offline. Images stay on your Mac.")
                .font(.caption).foregroundColor(.secondary)
            status
            if isModelOperation {
                OperationProgressView()
            } else if !message.isEmpty {
                Text(message).font(.caption).foregroundColor(.secondary)
            }
        }
        .fixedSize(horizontal: false, vertical: true)
        .onAppear { store.refreshStatus() }
    }

    @ViewBuilder private var status: some View {
        if #available(macOS 15.0, *) {
            switch store.status {
            case .checking:
                Label("Checking model…", systemImage: "magnifyingglass").font(.caption)
            case .notInstalled:
                Text("Not installed. The model is not included in DropShelf.").font(.caption).foregroundColor(.secondary)
                installButton("Download model (496 MB)")
            case .needsPreparation:
                Text("Downloaded. Finish setup to make it ready on this Mac. Damaged files may need to download again.").font(.caption).foregroundColor(.secondary)
                installButton("Finish installation")
                removeButton
            case .downloading, .compiling:
                if !isModelOperation {
                    ProgressView("Preparing model…").controlSize(.small)
                }
            case .ready:
                Label("Installed and ready to use", systemImage: "checkmark.seal.fill")
                    .font(.caption).foregroundColor(.green)
                removeButton
            case .failed(let error):
                Label(error, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption).foregroundColor(.orange)
                installButton("Retry model installation (up to 496 MB)")
                removeButton
            }
        } else {
            Text("Quality requires macOS 15 or later. Apple Vision is available on macOS 14 without a download.")
                .font(.caption).foregroundColor(.secondary)
        }
    }

    private var isModelOperation: Bool {
        operation.isRunning && [Self.installTitle, Self.removeTitle].contains(operation.title)
    }

    private func installButton(_ title: String) -> some View {
        Button(title, action: install)
            .buttonStyle(.borderedProminent).controlSize(.small)
            .disabled(operation.isRunning)
    }

    @ViewBuilder private var removeButton: some View {
        if allowsRemoval {
            Button("Remove downloaded model", action: remove).disabled(operation.isRunning)
                .controlSize(.small)
                .help("Free model storage. You can download it again anytime.")
        }
    }

    private func install() {
        message = ""
        operation.start(title: Self.installTitle, inputs: []) { context in
            _ = try store.installModel(context: context)
            return OperationResult(message: "Quality model installed and ready to use")
        } completion: { _, result in message = result }
    }

    private func remove() {
        message = ""
        operation.start(title: Self.removeTitle, inputs: [], cancellable: false) { context in
            try store.removeInstalledModel(context: context)
            return OperationResult(message: "Downloaded model removed")
        } completion: { _, result in message = result }
    }
}
