//
//  OnboardingView.swift
//  OpenSuperMLX
//
//  Created by user on 08.02.2025.
//

import Foundation
import SwiftUI
import MLXAudioSTT

struct OnboardingMLXModel: Identifiable {
    let id: String
    let name: String
    let repoID: String
    let size: String
    let description: String
    var isDownloaded: Bool = false

    init(from model: MLXModel) {
        self.id = model.id
        self.name = model.name
        self.repoID = model.repoID
        self.size = model.size
        self.description = model.description
    }
}

class OnboardingViewModel: ObservableObject {
    @Published var selectedLanguage: String {
        didSet {
            AppPreferences.shared.mlxLanguage = selectedLanguage
        }
    }
    
    @Published var useAsianAutocorrect: Bool {
        didSet {
            AppPreferences.shared.useAsianAutocorrect = useAsianAutocorrect
        }
    }
    
    @Published var models: [OnboardingMLXModel] = []
    @Published var selectedModelId: String?
    @Published var isDownloading: Bool = false
    @Published var downloadingModelName: String?
    @Published var downloadProgress: Double?

    private var downloadTask: Task<Void, Error>?

    init() {
        AppPreferences.shared.mlxLanguage = "auto"
        self.selectedLanguage = "auto"
        self.useAsianAutocorrect = AppPreferences.shared.useAsianAutocorrect
        
        initializeModels()
    }

    func initializeModels() {
        models = MLXModelManager.builtInModels.map { OnboardingMLXModel(from: $0) }
    }
    
    var canContinue: Bool {
        guard let selectedId = selectedModelId else { return false }
        return models.contains { $0.id == selectedId && $0.isDownloaded }
    }
    
    func selectModel(_ model: OnboardingMLXModel) {
        selectedModelId = model.id
        AppPreferences.shared.selectedMLXModel = model.repoID
    }

    @MainActor
    func downloadModel(_ model: OnboardingMLXModel) async throws {
        guard !isDownloading else { return }
        
        isDownloading = true
        downloadingModelName = model.name
        
        defer {
            isDownloading = false
            downloadingModelName = nil
            downloadProgress = nil
        }
        
        downloadTask = Task {
            let _ = try await Qwen3ASRModel.fromPretrained(model.repoID, progressHandler: { [weak self] progress in
                self?.downloadProgress = progress.fractionCompleted
            })
        }
        
        do {
            try await downloadTask?.value
        } catch is CancellationError {
            return
        }
        
        guard !Task.isCancelled else { return }
        
        if let index = self.models.firstIndex(where: { $0.id == model.id }) {
            self.models[index].isDownloaded = true
        }
        self.selectModel(model)
    }
    
    func cancelDownload() {
        downloadTask?.cancel()
        isDownloading = false
        downloadingModelName = nil
        downloadProgress = nil
    }
}

struct OnboardingView: View {
    @StateObject private var viewModel = OnboardingViewModel()
    @EnvironmentObject private var appState: AppState
    @State private var showError = false
    @State private var errorMessage = ""
    
    var body: some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 16) {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Welcome to")
                        .font(.title2)
                        .fontWeight(.medium)
                        .foregroundColor(.secondary)
                    
                    Text("OpenSuperMLX")
                        .font(.system(size: 32, weight: .bold))
                        .foregroundStyle(
                            .white
                        )
                }
                .padding(.bottom, 8)
                
                HStack(spacing: 8) {
                    
                    Picker("Language", selection: $viewModel.selectedLanguage) {
                        ForEach(LanguageUtil.availableLanguages, id: \.self) { code in
                            Text(LanguageUtil.languageNames[code] ?? code)
                                .tag(code)
                        }
                    }
                    .pickerStyle(.menu)
                    .frame(width: 150)
                }
                
                if Settings.asianLanguages.contains(viewModel.selectedLanguage) {
                    Toggle(isOn: $viewModel.useAsianAutocorrect) {
                        Text("Use Asian Autocorrect")
                            .font(.caption)
                    }
                    .toggleStyle(SwitchToggleStyle(tint: Color.accentColor))
                }
            }
            .padding(20)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                LinearGradient(
                    colors: [
                        Color.white.opacity(0.05),
                        Color.white.opacity(0.03),
                        Color.clear
                    ],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
            )
            
            Divider()
            
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    VStack(alignment: .leading, spacing: 12) {
                        Text("MLX Model")
                            .font(.headline)
                            .fontWeight(.semibold)
                        
                        Text("Download an MLX model to get started")
                            .font(.subheadline)
                            .foregroundColor(.secondary)
                        
                        VStack(spacing: 8) {
                            ForEach($viewModel.models) { $model in
                                OnboardingMLXModelItemView(model: $model, viewModel: viewModel)
                            }
                        }
                    }
                }
                .padding(12)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            
            Divider()
            
            HStack {
                Spacer()
                Button(action: {
                    handleContinueButtonTap()
                }) {
                    HStack(spacing: 6) {
                        Text("Continue")
                        Image(systemName: "arrow.right")
                            .font(.system(size: 12, weight: .semibold))
                    }
                    .frame(minWidth: 100)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .disabled(!viewModel.canContinue || viewModel.isDownloading)
            }
            .padding(16)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(
            ZStack {
                Color(.windowBackgroundColor)
                LinearGradient(
                    colors: [
                        Color.blue.opacity(0.02),
                        Color.clear,
                        Color.purple.opacity(0.02)
                    ],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
            }
        )
        .alert("Download Error", isPresented: $showError) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(errorMessage)
        }
    }

    private func handleContinueButtonTap() {
        appState.hasCompletedOnboarding = true
    }
}

struct OnboardingMLXModelItemView: View {
    @Binding var model: OnboardingMLXModel
    @ObservedObject var viewModel: OnboardingViewModel
    @State private var showError = false
    @State private var errorMessage = ""
    
    var isSelected: Bool {
        viewModel.selectedModelId == model.id
    }
    
    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text(model.name)
                        .font(.subheadline)
                        .fontWeight(.medium)
                    
                    Text(model.size)
                        .font(.caption2)
                        .foregroundColor(.secondary)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Capsule().fill(Color(.controlBackgroundColor)))
                    
                    if model.isDownloaded {
                        Image(systemName: "arrow.down.circle.fill")
                            .foregroundColor(.blue)
                            .imageScale(.small)
                    }
                }
                
                Text(model.description)
                    .font(.caption)
                    .foregroundColor(.secondary)
                
                if viewModel.isDownloading && viewModel.downloadingModelName == model.name {
                    VStack(spacing: 4) {
                        if let progress = viewModel.downloadProgress,
                           progress > 0, progress < 1 {
                            ProgressView(value: progress)
                                .progressViewStyle(.linear)
                            Text("\(Int(progress * 100))%")
                                .font(.caption2)
                                .foregroundColor(.secondary)
                        } else {
                            ProgressView()
                                .progressViewStyle(CircularProgressViewStyle())
                                .scaleEffect(0.7)
                        }
                    }
                    .padding(.top, 4)
                }
            }
            
            Spacer()
            
            if viewModel.isDownloading && viewModel.downloadingModelName == model.name {
                Button("Cancel") {
                    viewModel.cancelDownload()
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            } else if model.isDownloaded {
                if isSelected {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundColor(.green)
                        .imageScale(.large)
                } else {
                    Button(action: {
                        viewModel.selectModel(model)
                    }) {
                        Text("Select")
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                }
            } else {
                Button(action: {
                    Task {
                        do {
                            try await viewModel.downloadModel(model)
                        } catch is CancellationError {
                            // Don't show error for manual cancellation
                        } catch {
                            errorMessage = error.localizedDescription
                            showError = true
                        }
                    }
                }) {
                    Label("Download", systemImage: "arrow.down.circle")
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .disabled(viewModel.isDownloading)
            }
        }
        .padding(14)
        .background(
            RoundedRectangle(cornerRadius: 10)
                .fill(isSelected ? Color(.controlBackgroundColor).opacity(0.8) : Color(.controlBackgroundColor).opacity(0.5))
                .shadow(color: isSelected ? Color.blue.opacity(0.2) : Color.black.opacity(0.05), radius: isSelected ? 8 : 4, x: 0, y: 2)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .stroke(isSelected ? Color.blue.opacity(0.3) : Color.clear, lineWidth: 1.5)
        )
        .contentShape(Rectangle())
        .onTapGesture {
            if model.isDownloaded && !isSelected {
                viewModel.selectModel(model)
            }
        }
        .alert("Download Error", isPresented: $showError) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(errorMessage)
        }
    }
}

#Preview {
    OnboardingView()
}
