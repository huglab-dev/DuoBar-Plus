#if DEBUG
import AppKit
import SwiftUI

struct DebugPerformanceDiagnosticsView: View {
    @AppStorage(PreferenceKeys.simulateDesktopMac) private var simulateDesktopMac = false
    @AppStorage(PreferenceKeys.adaptiveRingColorCoding) private var adaptiveRingColorCoding = false
    @ObservedObject private var monitor = AdaptiveRingMonitor.shared
    @ObservedObject private var ssidDiagnostics = SSIDDiagnosticCenter.shared
    @State private var monitorOwner = UUID()
    @StateObject private var visualLab = AdaptiveRingVisualLabController()
    private let deviceContextService = DeviceContextService()

    private var context: DeviceContext {
        deviceContextService.current(simulateDesktop: simulateDesktopMac)
    }

    var body: some View {
        Section("Adaptive Ring · Debug") {
            Toggle("Simulate Desktop Mac", isOn: $simulateDesktopMac)

            Picker("Test Source", selection: $visualLab.source) {
                ForEach(AdaptiveRingTestSource.allCases) { source in
                    Text(source.rawValue).tag(source)
                }
            }

            if visualLab.source == .synthetic {
                Button("Reset Simulation") {
                    visualLab.resetSimulation(isDesktopSimulationEnabled: simulateDesktopMac)
                }
                .disabled(!simulateDesktopMac)
                Picker("Synthetic behavior", selection: $labBehavior) {
                    Text("Static Scenario").tag(0)
                    Text("Transition Sequence").tag(1)
                    Text("Multi-Metric Intelligence").tag(2)
                }
                if labBehavior == 0 {
                    Picker("Scenario", selection: $visualLab.scenario) {
                        ForEach(AdaptiveRingSyntheticScenario.allCases) { scenario in
                            Text(scenario.rawValue).tag(scenario)
                        }
                    }
                } else if labBehavior == 1 {
                    Picker("Sequence", selection: $visualLab.sequence) {
                        ForEach(AdaptiveRingSyntheticSequence.allCases) { sequence in
                            Text(sequence.rawValue).tag(sequence)
                        }
                    }
                    Button(visualLab.isPlayingSequence ? "Stop Sequence" : "Play Sequence") {
                        if visualLab.isPlayingSequence {
                            visualLab.stopSequence()
                            visualLab.apply(isDesktopSimulationEnabled: simulateDesktopMac)
                        } else {
                            visualLab.playSequence(isDesktopSimulationEnabled: simulateDesktopMac)
                        }
                    }
                    .disabled(!simulateDesktopMac)
                } else {
                    Picker("Combination", selection: $visualLab.intelligenceScenario) {
                        ForEach(AdaptiveRingIntelligenceScenario.allCases) { scenario in
                            Text(scenario.rawValue).tag(scenario)
                        }
                    }
                    Picker("Preference", selection: $visualLab.preference) {
                        ForEach(PerformancePreference.allCases, id: \.self) { preference in
                            Text(preference.rawValue).tag(preference)
                        }
                    }
                }

                if !simulateDesktopMac {
                    Text("Enable Simulate Desktop Mac to apply synthetic Adaptive Ring input.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            LabeledContent("Device behavior", value: context.ringBehavior.rawValue)
            LabeledContent("Internal battery", value: context.hasInternalBattery ? "Detected" : "Not detected")
            LabeledContent("Main display", value: displayLabel)
            LabeledContent("Brightness", value: brightnessLabel)
            LabeledContent("CPU", value: percent(monitor.performanceSnapshot?.cpuLoad))
            LabeledContent("Memory estimate", value: memoryLabel)
            LabeledContent("Thermal", value: thermalLabel)
            LabeledContent("Performance", value: monitor.performanceDecision.activeMetric.rawValue)
            LabeledContent("Engine mode", value: monitor.debugEngineMode.rawValue)
            LabeledContent("Engine session", value: "#\(monitor.debugEngineGeneration)")
            LabeledContent("Active duration", value: duration(monitor.performanceDecision.activeDuration))
            LabeledContent("Severity", value: monitor.performanceDecision.severity.semanticLabel)
            LabeledContent("Decision reason", value: monitor.performanceDecision.reason.rawValue)
            LabeledContent("Attention score", value: String(format: "%.1f", monitor.performanceDecision.attentionScore))
            LabeledContent("Adaptive state", value: monitor.state.diagnosticLabel)
            LabeledContent("Visual target", value: AdaptiveRingDiagnosticFormatter.visualTarget(monitor.state))
            LabeledContent("Displayed progress", value: "Animated in menu bar")
            LabeledContent("Color Coding", value: adaptiveRingColorCoding ? "On" : "Off")
            LabeledContent("Resolved color", value: colorPresentation.role.rawValue.capitalized)
            LabeledContent("Color intensity", value: String(format: "%.0f%%", colorPresentation.intensity * 100))

            Section("Display Brightness · Hardware Diagnostic") {
                if let diagnostic = monitor.brightnessSnapshot?.diagnostic {
                    Text(diagnostic.copyableReport)
                        .font(.system(.caption, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                } else {
                    Text("Activate Adaptive Ring monitoring to capture a public IOKit brightness-read diagnostic.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Section("Network / SSID · Hardware Diagnostic") {
                Text(ssidDiagnosticReport)
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)

                HStack {
                    Button("Copy Report", action: copySSIDDiagnosticReport)
                    Button("Refresh") { ssidDiagnostics.requestRefresh() }
                }
            }

            if visualLab.source == .synthetic {
                Section("Synthetic input") {
                    LabeledContent("Scenario", value: monitor.debugScenarioLabel ?? "Pending")
                    LabeledContent("Brightness", value: syntheticBrightness)
                    LabeledContent("Synthetic CPU", value: percent(monitor.performanceSnapshot?.cpuLoad))
                    LabeledContent("Synthetic memory", value: memoryLabel)
                    LabeledContent("Synthetic thermal", value: thermalLabel)
                    LabeledContent("CPU severity", value: severity(for: .cpu))
                    LabeledContent("CPU duration", value: duration(for: .cpu))
                    LabeledContent("Memory severity", value: severity(for: .memory))
                    LabeledContent("Memory duration", value: duration(for: .memory))
                    LabeledContent("Thermal severity", value: severity(for: .thermal))
                    LabeledContent("Thermal duration", value: duration(for: .thermal))
                    LabeledContent("Candidate duration", value: duration(monitor.performanceDecision.candidateDuration))
                    LabeledContent("Challenger", value: monitor.performanceDecision.challenger?.metric.rawValue ?? "None")
                    LabeledContent("Challenger duration", value: duration(monitor.performanceDecision.challengerDuration))
                    LabeledContent("Preference affected", value: monitor.performanceDecision.preferenceAffectedSelection ? "Yes" : "No")
                    LabeledContent("Critical override", value: monitor.performanceDecision.isCriticalOverride ? "Yes" : "No")
                    LabeledContent("Release state", value: monitor.performanceDecision.isReleasePending ? "Release delay" : "Active")
                    LabeledContent("Center presentation", value: monitor.performanceDecision.activeMetric == .idle ? "Network" : monitor.performanceDecision.activeMetric.rawValue.capitalized)
                    LabeledContent("Audio priority", value: "Use existing audio debug control / hardware test")
                }
            }
        }
        .onAppear {
            monitor.acquire(owner: monitorOwner)
            visualLab.apply(isDesktopSimulationEnabled: simulateDesktopMac)
        }
        .onDisappear {
            visualLab.reset()
            monitor.release(owner: monitorOwner)
        }
        .onChange(of: simulateDesktopMac) { _ in visualLab.apply(isDesktopSimulationEnabled: simulateDesktopMac) }
        .onChange(of: visualLab.source) { _ in visualLab.apply(isDesktopSimulationEnabled: simulateDesktopMac) }
        .onChange(of: visualLab.scenario) { _ in
            guard labBehavior == 0 else { return }
            visualLab.apply(isDesktopSimulationEnabled: simulateDesktopMac)
        }
        .onChange(of: visualLab.intelligenceScenario) { _ in
            guard labBehavior == 2 else { return }
            visualLab.applyIntelligenceScenario(isDesktopSimulationEnabled: simulateDesktopMac)
        }
        .onChange(of: visualLab.preference) { _ in
            if labBehavior == 2 {
                visualLab.applyIntelligenceScenario(isDesktopSimulationEnabled: simulateDesktopMac)
            } else {
                visualLab.apply(isDesktopSimulationEnabled: simulateDesktopMac)
            }
        }
        .onChange(of: labBehavior) { _ in
            visualLab.labUsesIntelligence = labBehavior == 2
            if labBehavior == 2 {
                visualLab.applyIntelligenceScenario(isDesktopSimulationEnabled: simulateDesktopMac)
            } else {
                visualLab.apply(isDesktopSimulationEnabled: simulateDesktopMac)
            }
        }
    }

    private var displayLabel: String {
        monitor.brightnessSnapshot?.mainDisplay.diagnosticLabel ?? "Sampling…"
    }

    private var ssidDiagnosticReport: String {
        ssidDiagnostics.diagnostic?.copyableReport ?? "Waiting for the first NetworkService snapshot…"
    }

    private func copySSIDDiagnosticReport() {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(ssidDiagnosticReport, forType: .string)
    }

    private var brightnessLabel: String {
        guard let brightness = monitor.brightnessSnapshot?.availability else { return "Sampling…" }
        switch brightness {
        case .available(let value): return percent(value)
        case .unavailable: return "Unavailable"
        }
    }

    @State private var labBehavior = 0

    private var syntheticBrightness: String {
        brightnessLabel
    }

    private var memoryLabel: String {
        guard let stress = monitor.performanceSnapshot?.memory?.stress else { return "Unavailable" }
        return String(describing: stress).capitalized
    }

    private var thermalLabel: String {
        guard let thermal = monitor.performanceSnapshot?.thermalState else { return "Unavailable" }
        return String(describing: thermal).capitalized
    }

    private func percent(_ value: Double?) -> String {
        guard let value else { return "Sampling…" }
        return value.formatted(.percent.precision(.fractionLength(1)))
    }

    private func duration(_ value: TimeInterval) -> String { String(format: "%.1fs", value) }

    private func severity(for metric: PerformanceMetric) -> String {
        monitor.debugCandidates.first { $0.metric == metric }?.severity.semanticLabel ?? "Normal"
    }

    private func duration(for metric: PerformanceMetric) -> String {
        duration(monitor.debugCandidateDurations[metric] ?? 0)
    }

    private var colorPresentation: AdaptiveRingColorPresentation {
        AdaptiveRingColorResolver.resolve(
            state: monitor.state,
            decision: monitor.performanceDecision,
            colorCodingEnabled: adaptiveRingColorCoding
        )
    }
}
#endif
