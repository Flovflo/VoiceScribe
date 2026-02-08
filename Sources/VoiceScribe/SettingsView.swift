import SwiftUI
import VoiceScribeCore

struct SettingsView: View {
    @ObservedObject var appState = AppState.shared
    private let requiredModel = "mlx-community/Qwen3-ASR-1.7B-8bit"
    
    var body: some View {
        Form {
            Section {
                VStack(alignment: .leading, spacing: 12) {
                    Text("Speech Recognition Model")
                        .font(.headline)

                    Text(requiredModel)
                        .font(.system(size: 12, weight: .medium, design: .monospaced))
                        .foregroundColor(.primary)

                    Text("Locked for quality and consistency.")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
                .padding(.vertical, 5)
            }
            
            Divider()
            
            Section {
                HStack {
                    Text("Engine Status:")
                    Spacer()
                    Text(appState.status)
                        .foregroundColor(.secondary)
                        .multilineTextAlignment(.trailing)
                }
            }
            
            Spacer()
            
            Text("VoiceScribe v1.1 • Powered by Qwen3-ASR")
                .font(.caption2)
                .foregroundColor(.secondary.opacity(0.8))
                .frame(maxWidth: .infinity, alignment: .center)
        }
        .padding(20)
        .frame(width: 400, height: 300)
    }
}
