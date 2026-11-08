import AppKit
import SwiftUI

/// The MIT license of the original DuoBar, shipped inside the app as the
/// license requires. `DuoBar/LICENSE.txt` must stay identical to `LICENSE`.
enum AppLicense {
    static let originalProjectURL = URL(string: "https://github.com/Mikeli7666/DuoBar")!

    static func text(in bundle: Bundle = .main) -> String? {
        guard let url = bundle.url(forResource: "LICENSE", withExtension: "txt") else { return nil }
        return try? String(contentsOf: url, encoding: .utf8)
    }

    /// The same words with the file's hard line breaks removed, so paragraphs
    /// wrap to the width of the window.
    static func reflowed(_ text: String) -> String {
        text.trimmingCharacters(in: .whitespacesAndNewlines)
            .components(separatedBy: "\n\n")
            .map { $0.replacingOccurrences(of: "\n", with: " ") }
            .joined(separator: "\n\n")
    }
}

/// DuoBar+: who made it, and the credit the MIT license asks for.
struct AboutCreditsView: View {
    @State private var showsLicense: Bool

    init(showsLicense: Bool = false) {
        _showsLicense = State(initialValue: showsLicense)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Image("HuglabWordmark")
                .resizable()
                .scaledToFit()
                .frame(width: 130)
                .padding(.vertical, 6)
                .accessibilityLabel("huglab")
            Text(localized("Developed by Hugo Bjurström"))
        }

        Link(destination: AppLicense.originalProjectURL) {
            HStack {
                Text(localized("Based on DuoBar by Mike Li"))
                    .foregroundStyle(.primary)
                Spacer()
                Image(systemName: "arrow.up.forward.app")
                    .foregroundStyle(.secondary)
            }
        }

        DisclosureGroup(localized("MIT License"), isExpanded: $showsLicense) {
            Text(verbatim: AppLicense.text().map(AppLicense.reflowed) ?? "")
                .font(.caption2)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)
                .padding(.top, 4)
        }
    }
}
