import Foundation
import MLXLLM
import MLXLMCommon

enum LocalRoleModelState: Equatable {
    case notInstalled
    case downloading(progress: Double)
    case installed
    case analyzing
    case failed(String)
}

enum LocalNovelRoleModelError: LocalizedError {
    case notInstalled

    var errorDescription: String? {
        switch self {
        case .notInstalled: "请先下载本地角色理解模型"
        }
    }
}

actor LocalNovelRoleModel {
    static func isInstalled(_ variant: LocalRoleModelVariant) -> Bool {
        let directory = ModelConfiguration(id: variant.repositoryID).modelDirectory()
        let fileManager = FileManager.default
        let hasConfiguration = fileManager.fileExists(atPath: directory.appendingPathComponent("config.json").path)
        let hasWeights = (try? fileManager.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil))?
            .contains { $0.pathExtension == "safetensors" } == true
        return hasConfiguration && hasWeights
    }

    func download(
        _ variant: LocalRoleModelVariant,
        progress: @Sendable @escaping (Double) -> Void
    ) async throws {
        let configuration = ModelConfiguration(id: variant.repositoryID)
        _ = try await LLMModelFactory.shared.loadContainer(
            configuration: configuration,
            progressHandler: { value in progress(value.fractionCompleted) }
        )
    }

    func analyze(
        pages: [ReaderPage],
        fallback: ReadAloudRolePlan,
        variant: LocalRoleModelVariant,
        progress: @Sendable @escaping (Int, Int) -> Void = { _, _ in }
    ) async throws -> ReadAloudRolePlan {
        guard Self.isInstalled(variant) else { throw LocalNovelRoleModelError.notInstalled }
        let inputs = NovelRoleAnalysisCodec.makeInputs(
            pages: pages,
            maximumCharacters: 5_000,
            maximumSentences: 24
        )
        guard !inputs.isEmpty else { return fallback }
        let container = try await LLMModelFactory.shared.loadContainer(
            configuration: ModelConfiguration(id: variant.repositoryID)
        )
        var combined = fallback
        var successfulBatches = 0
        var lastError: Error?
        progress(0, inputs.count)
        for (index, input) in inputs.enumerated() {
            try Task.checkCancellation()
            let session = ChatSession(
                container,
                instructions: "关闭思考过程，只输出严格 JSON。不要输出 Markdown。",
                generateParameters: GenerateParameters(maxTokens: 1_200, temperature: 0)
            )
            do {
                let content = try await session.respond(to: "/no_think\n\(input.prompt)")
                combined = try NovelRoleAnalysisCodec.decode(
                    content: content,
                    input: input,
                    fallback: combined
                )
                successfulBatches += 1
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                lastError = error
            }
            progress(index + 1, inputs.count)
        }
        if successfulBatches == 0, let lastError { throw lastError }
        return combined
    }

    func remove(_ variant: LocalRoleModelVariant) throws {
        let directory = ModelConfiguration(id: variant.repositoryID).modelDirectory()
        let modelName = variant.repositoryID.split(separator: "/").last.map(String.init) ?? ""
        guard !modelName.isEmpty, directory.standardizedFileURL.path.contains(modelName) else { return }
        if FileManager.default.fileExists(atPath: directory.path) {
            try FileManager.default.removeItem(at: directory)
        }
    }
}
