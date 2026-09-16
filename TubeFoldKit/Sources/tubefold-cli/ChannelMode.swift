import Foundation
import TubeFoldKit

// Channel mode: a channel URL instead of a video URL dumps every video's
// transcript into one folder (no provider, no summary). The folder path is the
// stdout contract, mirroring the single-video mode's saved-file path.

struct ChannelModeOptions {
    let outputDirectory: URL
    let tabs: [ChannelTab]
    let limit: Int?
    let allowAny: Bool
    let skipExisting: Bool
    let writeIndex: Bool
    let openAfterSave: Bool
}

/// Parse a `--tabs videos,shorts` value; an unknown name is fatal.
func parseChannelTabs(_ raw: String?, urlTab: ChannelTab?) -> [ChannelTab] {
    guard let raw, !raw.trimmingCharacters(in: .whitespaces).isEmpty else {
        return [urlTab ?? .videos]
    }
    let names = raw.split(separator: ",").map {
        $0.trimmingCharacters(in: .whitespaces).lowercased()
    }
    var tabs: [ChannelTab] = []
    for name in names {
        guard let tab = ChannelTab(rawValue: name) else {
            die("Unknown tab: \(name) (expected videos, shorts or streams)", code: 2)
        }
        if !tabs.contains(tab) {
            tabs.append(tab)
        }
    }
    return tabs
}

func runChannelExport(
    reference: YouTubeChannelReference,
    options: ChannelModeOptions,
    logger: CLILogger
) async -> Never {
    let tabList = options.tabs.map(\.rawValue).joined(separator: ", ")
    logger.info("Channel: \(reference.label) — listing \(tabList)…")

    let exporter = ChannelTranscriptExporter(client: InnerTubeClient())
    let exportOptions = ChannelExportOptions(
        outputDirectory: options.outputDirectory,
        tabs: options.tabs,
        limit: options.limit,
        allowAnyTranscriptLanguage: options.allowAny,
        skipExisting: options.skipExisting,
        writeIndex: options.writeIndex
    )

    do {
        let summary = try await exporter.export(
            reference: reference,
            options: exportOptions,
            onListing: { listing in
                logger.info("\(listing.title): \(listing.videos.count) videos")
            },
            onProgress: { progress in
                let item = progress.item
                let label = item.title.isEmpty ? item.videoID : item.title
                let position = "[\(progress.index)/\(progress.total)]"
                switch item.outcome {
                case let .saved(path):
                    logger.info("\(position) \(item.publishedAt) \(label)")
                    logger.debug("saved: \(path)")
                case let .skipped(reason):
                    logger.info("\(position) skipped (\(reason)) — \(label)")
                case .noCaptions:
                    logger.info("\(position) no captions — \(label)")
                case let .failed(message):
                    logger.info("\(position) FAILED — \(label): \(message)")
                }
            }
        )
        logger.info(
            "Saved \(summary.saved), skipped \(summary.skipped), "
                + "no captions \(summary.noCaptions), failed \(summary.failed)"
        )
        logger.info("Folder: \(summary.folder.path)")
        print(summary.folder.path)

        if options.openAfterSave {
            let open = Process()
            open.executableURL = URL(fileURLWithPath: "/usr/bin/open")
            open.arguments = [summary.folder.path]
            try? open.run()
        }
        exit(summary.saved == 0 && summary.failed + summary.noCaptions > 0 ? 1 : 0)
    } catch let error as ChannelBrowseError {
        die(error.userMessage)
    } catch let error as InnerTubeError {
        die(error.userMessage)
    } catch {
        die("\(error)")
    }
}
