import AppKit
import DesertAntUI
import SwiftUI

/// The credit the model license asks an app shipping the models to show.
enum About {
    static let homepage = URL(string: "https://desertant.com")!
    static let windowID = "about"
    static let acknowledgementsID = "acknowledgements"
    static let footer = "Eleven on-device models from Desert Ant Labs, in flows you build. Your recordings, text, and photos never leave this Mac."
}

struct AboutView: View {
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        VStack(spacing: 0) {
            Image(nsImage: NSApp.applicationIconImage).resizable().frame(width: 76, height: 76)
            Text("Desert Ant Flow").font(.title2.weight(.semibold)).padding(.top, 10)
            Text(version).font(.callout).foregroundStyle(.secondary).padding(.top, 2)
            Text(About.footer)
                .font(.callout).foregroundStyle(.secondary).multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true).padding(.top, 16)
            Link(destination: About.homepage) { DA.Attribution() }.buttonStyle(.plain).padding(.top, 18)
            Button("Acknowledgements") { openWindow(id: About.acknowledgementsID) }
                .buttonStyle(.link).font(.caption).padding(.top, 14)
            Text(string("NSHumanReadableCopyright"))
                .font(.caption).foregroundStyle(.tertiary).multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true).padding(.top, 18)
        }
        .padding(.horizontal, 36).padding(.vertical, 32)
        .frame(width: 360)
    }

    private var version: String {
        let short = string("CFBundleShortVersionString"), build = string("CFBundleVersion")
        return build.isEmpty ? "Version \(short)" : "Version \(short) (\(build))"
    }

    private func string(_ key: String) -> String { Bundle.main.object(forInfoDictionaryKey: key) as? String ?? "" }
}

/// The third-party notices and the full text of every license Flow ships
/// under, as the licenses ask a binary to carry them.
struct AcknowledgementsView: View {
    private struct Notice: Identifiable {
        let id: String
        let text: String
    }

    /// THIRD_PARTY_NOTICES.md first, then each license in LICENSES/ by name.
    private let notices: [Notice] = {
        guard let resources = Bundle.main.resourceURL else { return [] }
        let folder = resources.appending(path: "LICENSES")
        let files = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? []
        let all = [resources.appending(path: "THIRD_PARTY_NOTICES.md")]
            + files.sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
        return all.compactMap { url in
            (try? String(contentsOf: url, encoding: .utf8)).map { Notice(id: url.deletingPathExtension().lastPathComponent, text: $0) }
        }
    }()

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 28) {
                ForEach(notices) { notice in
                    VStack(alignment: .leading, spacing: 10) {
                        Text(notice.id).font(.headline)
                        Text(notice.text)
                            .font(.system(.caption, design: .monospaced))
                            .foregroundStyle(.secondary)
                            .textSelection(.enabled)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
            .padding(28)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(minWidth: 520, minHeight: 420)
    }
}
