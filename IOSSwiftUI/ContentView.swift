import SwiftUI

// SwiftUI front-end for the smoke test: controls + status + scrollable log output.
struct ContentView: View {
    // Observable model that owns the engine and log output.
    @State private var model = EngineModel()
    // When enabled, the log view scrolls to the newest line as output arrives.
    @State private var autoScroll = true

    var body: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: 16) {
                // Primary controls and run status.
                HStack(spacing: 12) {
                    Button {
                        model.runSmokeTest()
                    } label: {
                        Text("Run")
                    }
                    .font(.body)
                    .buttonStyle(.borderedProminent)
                    .disabled(model.isRunning)
                    .controlSize(.regular)

                    Button {
                        model.stop()
                    } label: {
                        Text("Stop")
                    }
                    .font(.body)
                    .buttonStyle(.bordered)
                    .disabled(!model.isRunning)
                    .controlSize(.regular)

                    Button {
                        model.clear()
                    } label: {
                        Text("Clear")
                    }
                    .font(.body)
                    .buttonStyle(.bordered)
                    .disabled(model.log.isEmpty)
                    .controlSize(.regular)

                    Spacer()

                    // Running indicator + status label.
                    HStack(spacing: 8) {
                        if model.isRunning {
                            ProgressView()
                                .progressViewStyle(.circular)
                        }
                        Text(model.status)
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                }

                Toggle("Auto-scroll", isOn: $autoScroll)
                    .toggleStyle(.switch)

                // Output section.
                VStack(alignment: .leading, spacing: 8) {
                    Text("Engine Output")
                        .font(.headline)

                    LogView(text: model.log, autoScroll: autoScroll)
                }
            }
            .padding()
            .navigationTitle("SFEngine Test")
        }
    }
}

// Reusable log view that preserves formatting and supports auto-scroll.
private struct LogView: View {
    let text: String
    let autoScroll: Bool

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                // Show a friendly placeholder before the first output arrives.
                if text.isEmpty {
                    ContentUnavailableView("No output yet", systemImage: "text.alignleft")
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 24)
                        .id("content")
                } else {
                    // Monospaced output keeps engine lines aligned and scannable.
                    Text(text)
                        .font(.system(.footnote, design: .monospaced))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(12)
                }

                // Anchor used by ScrollViewReader for auto-scroll.
                Color.clear
                    .frame(height: 1)
                    .id("bottom")
            }
            .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .stroke(.quaternary, lineWidth: 1)
            )
            // Auto-scroll whenever the log changes (if enabled).
            .onChange(of: text) { _, _ in
                guard autoScroll else { return }
                withAnimation(.easeOut(duration: 0.2)) {
                    proxy.scrollTo("bottom", anchor: .bottom)
                }
            }
        }
        .frame(minHeight: 240)
    }
}
