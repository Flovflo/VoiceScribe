import SwiftUI
import VoiceScribeCore

struct SettingsView: View {
    @ObservedObject var appState = AppState.shared
    @AppStorage("selectedModel") private var selectedModel: String = "mlx-community/Qwen3-ASR-1.7B-8bit"
    
    let models = [
        "mlx-community/Qwen3-ASR-0.6B-8bit",
        "mlx-community/Qwen3-ASR-1.7B-8bit"
    ]
    
    var body: some View {
        Form {
            Section {
                VStack(alignment: .leading, spacing: 12) {
                    Text("Speech Recognition Model")
                        .font(.headline)
                    
                    Picker("", selection: $selectedModel) {
                        ForEach(models, id: \.self) { model in
                            Text(model.replacingOccurrences(of: "mlx-community/", with: ""))
                                .tag(model)
                        }
                    }
                    .pickerStyle(.radioGroup)
                    .onChange(of: selectedModel) { _, newValue in
                        appState.engine.setModel(newValue)
                    }
                    
                    Text("1.7B is more accurate, 0.6B is faster.")
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
