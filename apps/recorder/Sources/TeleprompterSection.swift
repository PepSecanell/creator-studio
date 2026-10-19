import SwiftUI
import UniformTypeIdentifiers

/// The teleprompter controls in the main window.
///
/// Split out so the script text can be edited: `TeleprompterModel` is a
/// reference type living on the controller, and SwiftUI only produces
/// bindings into it through an `@ObservedObject`.
struct TeleprompterSection: View {

    @ObservedObject var model: TeleprompterModel
    let isVisible: Bool
    let toggle: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Label("Teleprompter", systemImage: "text.alignleft")
                    .font(.system(size: 12, weight: .semibold))
                Spacer()
                Button(isVisible ? "Hide" : "Show", action: toggle)
                    .controlSize(.small)
            }

            TextEditor(text: $model.text)
                .font(.system(size: 12))
                .frame(height: 160)
                .scrollContentBackground(.hidden)
                .padding(4)
                .background(
                    RoundedRectangle(cornerRadius: 6)
                        .fill(Color(nsColor: .textBackgroundColor))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 6)
                        .stroke(Color.secondary.opacity(0.25))
                )
                // SwiftUI's TextEditor paste on macOS goes through NSTextView's
                // rich-text path, which can silently drop everything after the
                // first blank line when the clipboard content carries any
                // paragraph styling (copied from a browser, Notes, a chat app,
                // etc). Intercepting the paste and inserting the plain string
                // ourselves sidesteps that entirely, this is what let a
                // multi-paragraph script cut off after the first paragraph.
                .onPasteCommand(of: [.plainText, .text]) { providers in
                    for provider in providers {
                        provider.loadObject(ofClass: NSString.self) { object, _ in
                            guard let pasted = object as? String, !pasted.isEmpty else { return }
                            DispatchQueue.main.async {
                                if model.text.isEmpty {
                                    model.text = pasted
                                } else {
                                    let needsBreak = !model.text.hasSuffix("\n")
                                    model.text += (needsBreak ? "\n" : "") + pasted
                                }
                            }
                        }
                    }
                }

            HStack(spacing: 8) {
                Text("Reads")
                    .font(.system(size: 12))
                    .frame(width: 66, alignment: .leading)
                Picker("", selection: $model.mode) {
                    ForEach(PrompterMode.allCases) { Text($0.label).tag($0) }
                }
                .labelsHidden()
                .pickerStyle(.segmented)
            }
            HStack(spacing: 8) {
                Text("Position")
                    .font(.system(size: 12))
                    .frame(width: 66, alignment: .leading)
                Picker("", selection: $model.position) {
                    ForEach(PrompterPosition.allCases) { Text($0.short).tag($0) }
                }
                .labelsHidden()
                // Five segments were ~440 pt wide: wider than the 400 pt window, so the whole
                // scroll content overflowed and both edges (and the padding) were cut off.
                .pickerStyle(.menu)
            }
            if model.mode == .follow, !model.speechStatus.isEmpty {
                Text(model.speechStatus)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
            HStack(spacing: 8) {
                Text("Text size")
                    .font(.system(size: 12))
                    .frame(width: 66, alignment: .leading)
                Slider(value: $model.fontSize, in: 18...54)
                Text("\(Int(model.fontSize))pt")
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .frame(width: 46, alignment: .trailing)
            }

            if TeleprompterScript.containsVoiceoverLine(model.text) {
                Label(
                    "This script has a voiceover line. Don't read it. Pause, hold a beat, carry on.",
                    systemImage: "pause.circle"
                )
                .font(.system(size: 11))
                .foregroundStyle(Color(red: 0.42, green: 0.62, blue: 0.53))
            }

            Text("Floats near the lens and stays out of the recording. Follow mode listens to your voice; ⌃⌥← and ⌃⌥→ step a box. Position > Set camera spot: drag the cross onto your lens and the reading line sits right under it. Faster + offline: turn on Dictation in System Settings > Keyboard.")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
        }
    }
}
