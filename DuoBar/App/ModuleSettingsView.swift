import SwiftUI

/// The Modules tab: which popover modules run, their order, and per-module
/// options. Turning a module off stops all of its work.
struct ModuleSettingsView: View {
    @StateObject private var model: ModuleSettingsModel

    init(hasInternalBattery: Bool) {
        _model = StateObject(wrappedValue: ModuleSettingsModel(hasInternalBattery: hasInternalBattery))
    }

    var body: some View {
        List {
            Section {
                ForEach(model.modules) { id in
                    moduleRow(id)
                }
                .onMove(perform: model.move)
            } header: {
                Text(localized("Modules"))
            } footer: {
                Text(localized("Drag to reorder. A module that is turned off does no work at all."))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            if !model.options.isEmpty {
                Section(localized("Options")) {
                    ForEach(model.options) { option in
                        optionRow(option)
                    }
                }
            }
        }
        .listStyle(.inset)
        .frame(width: 420, height: 380)
        .onReceive(NotificationCenter.default.publisher(for: UserDefaults.didChangeNotification)) { _ in
            model.reload()
        }
    }

    private func moduleRow(_ id: ModuleID) -> some View {
        let isSupported = model.isSupported(id)
        return HStack(spacing: 10) {
            Image(systemName: "line.3.horizontal")
                .foregroundStyle(.tertiary)
                .accessibilityHidden(true)
            Image(systemName: id.symbol)
                .frame(width: 18)
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 1) {
                Text(id.title)
                if !isSupported {
                    Text(localized("Not available on this Mac"))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer()
            Toggle(id.title, isOn: Binding(
                get: { isSupported && model.isEnabled(id) },
                set: { model.setEnabled($0, for: id) }
            ))
            .labelsHidden()
            .toggleStyle(.switch)
            .controlSize(.small)
            .disabled(!isSupported)
        }
        .padding(.vertical, 2)
    }

    private func optionRow(_ option: ModuleOption) -> some View {
        let moduleOn = model.isEnabled(option.module) && model.isSupported(option.module)
        return HStack(alignment: .firstTextBaseline, spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text(option.title)
                Text(option.footnote)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer()
            Toggle(option.title, isOn: Binding(
                get: { model.isEnabled(option) },
                set: { model.setEnabled($0, for: option) }
            ))
            .labelsHidden()
            .toggleStyle(.switch)
            .controlSize(.small)
        }
        .padding(.vertical, 2)
        .disabled(!moduleOn)
        .help(moduleOn ? "" : localized("Turn on the %@ module to change this.", option.module.title))
    }
}
