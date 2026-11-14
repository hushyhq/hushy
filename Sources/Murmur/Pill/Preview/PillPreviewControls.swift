import AppKit
import SwiftUI

/// The preview's control window: play the whole reel or one scene, slow it down, loop it. Plain
/// on purpose; the thing to look at is the pill.
struct PillPreviewControls: View {
    @Bindable var runner: PillPreviewRunner

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 4) {
                Text(runner.playing?.title ?? "Stopped")
                    .font(.system(size: 13, weight: .semibold))
                Text(runner.caption)
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, minHeight: 32, alignment: .topLeading)
            }

            HStack(spacing: 8) {
                Button("Play all") { runner.playAll() }
                    .keyboardShortcut(.defaultAction)
                Button("Stop") { runner.stop() }
                Button("Quit") { NSApp.terminate(nil) }
                Spacer()
                Toggle("Loop", isOn: $runner.loops)
                    .toggleStyle(.checkbox)
            }

            Picker("Speed", selection: $runner.speed) {
                Text("1×").tag(1.0)
                Text("½×").tag(0.5)
                Text("¼×").tag(0.25)
            }
            .pickerStyle(.segmented)

            Picker("Timings", selection: $runner.usesOldTimings) {
                Text("New").tag(false)
                Text("Old").tag(true)
            }
            .pickerStyle(.segmented)

            Picker("Reduce Motion", selection: $runner.reduceMotion) {
                ForEach(PillPreviewReduceMotion.allCases) { Text($0.title).tag($0) }
            }
            .pickerStyle(.segmented)

            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(PillPreviewScene.allCases) { scene in
                        Button { runner.play([scene]) } label: {
                            HStack {
                                Text(scene.title)
                                Spacer()
                                if runner.playing == scene {
                                    Image(systemName: "play.fill").font(.system(size: 9)).foregroundStyle(.secondary)
                                }
                            }
                            .contentShape(Rectangle())
                            .padding(.vertical, 4)
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("Play: \(scene.title)")
                    }
                }
            }

            Divider()

            Text("Every word is invented. No microphone, no model, and nothing is copied or pasted. The pill sits a little above its usual place so it does not cover the real one.")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(16)
        .frame(width: 340, height: 640, alignment: .top)
    }
}
