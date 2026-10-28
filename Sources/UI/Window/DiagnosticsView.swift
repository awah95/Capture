import AppKit
import SwiftUI

/// The audio self-test. Deliberately plain — this is an instrument, not a showcase.
struct DiagnosticsView: View {
    @ObservedObject var runner: DiagnosticsRunner
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    @State private var devices: [AudioInputDevice] = []
    @State private var selectedUID: String?
    @State private var voiceProcessing = true
    @State private var reportText = ""
    @State private var didCopy = false

    var body: some View {
        ZStack {
            CapturPalette.canvas.ignoresSafeArea()

            VStack(alignment: .leading, spacing: 18) {
                HStack(alignment: .top, spacing: 14) {
                    CapturMark()
                    CapturPageHeader(
                        title: "Diagnostics",
                        subtitle: "Test the same microphone path Captur uses, then copy a precise report."
                    )
                }

                CapturCard("Audio input", symbol: "mic") {
                    VStack(alignment: .leading, spacing: 14) {
                        HStack(spacing: 10) {
                            Picker("Input", selection: $selectedUID) {
                                Text("System default").tag(String?.none)
                                ForEach(devices) { device in
                                    Text(label(for: device)).tag(String?.some(device.id))
                                }
                            }
                            .frame(maxWidth: .infinity)

                            Button {
                                devices = runner.availableDevices()
                            } label: {
                                Label("Re-scan", systemImage: "arrow.clockwise")
                            }
                            .help("Re-scan input devices")
                        }

                        Toggle("Echo cancellation", isOn: $voiceProcessing)
                            .help("Cancels the Mac's own output so music or a call does not contaminate the transcript.")

                        levelMeter
                    }
                }

                CapturCard("Capture report", symbol: "waveform.badge.magnifyingglass") {
                    ScrollView {
                        Text(reportText.isEmpty
                             ? "Speak naturally while Captur records. Device, format, levels, and any capture error will appear here."
                             : reportText)
                            .font(.system(.callout, design: .monospaced))
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .foregroundStyle(reportText.isEmpty ? .secondary : .primary)
                            .padding(12)
                    }
                    .frame(minHeight: 180)
                    .capturSurface(inset: true, radius: 8)
                }
                .frame(maxHeight: .infinity)

                HStack(spacing: 10) {
                    Button {
                        Task {
                            let report = await runner.recordSample(seconds: 3,
                                                                   deviceUID: selectedUID,
                                                                   voiceProcessing: voiceProcessing)
                            reportText = report.formatted()
                            didCopy = false
                        }
                    } label: {
                        Label(runner.isRunning ? "Recording…" : "Record 3 seconds",
                              systemImage: runner.isRunning ? "waveform" : "record.circle")
                    }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
                    .disabled(runner.isRunning)

                    Spacer()

                    Button(didCopy ? "Copied" : "Copy report") {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(reportText, forType: .string)
                        didCopy = true
                    }
                    .disabled(reportText.isEmpty)

                    if let url = runner.lastAudioURL {
                        Button("Reveal audio") {
                            NSWorkspace.shared.activateFileViewerSelecting([url])
                        }
                    }
                }
            }
            .padding(24)
        }
        .frame(minWidth: 520, idealWidth: 620, minHeight: 520, idealHeight: 660)
        .tint(CapturPalette.accent)
        .onAppear { devices = runner.availableDevices() }
    }

    private var levelMeter: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text("Input level").font(.caption).foregroundStyle(.secondary)
            GeometryReader { geometry in
                ZStack(alignment: .leading) {
                    Capsule().fill(CapturPalette.inset)
                    Capsule()
                        .fill(runner.liveLevel > 0.01 ? CapturPalette.accent : Color.secondary)
                        .frame(width: max(0, min(1, runner.liveLevel)) * geometry.size.width)
                        .animation(reduceMotion ? nil : .linear(duration: 0.05),
                                   value: runner.liveLevel)
                }
            }
            .frame(height: 10)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Input level")
            .accessibilityValue("\(Int(max(0, min(1, runner.liveLevel)) * 100)) percent")
        }
    }

    private func label(for device: AudioInputDevice) -> String {
        var text = device.name
        if device.isContinuityDevice { text += "  (Continuity)" }
        return text
    }
}

@MainActor
final class DiagnosticsWindowController: NSWindowController, NSWindowDelegate {
    convenience init(runner: DiagnosticsRunner) {
        let hosting = NSHostingController(rootView: DiagnosticsView(runner: runner))
        let window = NSWindow(contentViewController: hosting)
        window.title = "Captur Diagnostics"
        window.styleMask = [.titled, .closable, .miniaturizable, .resizable]
        window.setContentSize(NSSize(width: 620, height: 660))
        window.contentMinSize = NSSize(width: 520, height: 520)
        window.center()
        self.init(window: window)
        window.delegate = self
    }

    func present() {
        CapturWindowPresentation.present(self)
    }

    func windowWillClose(_ notification: Notification) {
        CapturWindowPresentation.restoreAccessoryPolicy(excluding: window)
    }
}
