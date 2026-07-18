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
        variant: LocalRoleModelVariant
    ) async throws -> ReadAloudRolePlan {
        guard Self.isInstalled(variant) else { throw LocalNovelRoleModelError.notInstalled }
        let input = NovelRoleAnalysisCodec.makeInput(pages: pages, maximumCharacters: 14_000)
        let container = try await LLMModelFactory.shared.loadContainer(
            configuration: ModelConfiguration(id: variant.repositoryID)
        )
        let session = ChatSession(
            container,
            instructions: "你只输出严格 JSON，不输出分析过程。",
            generateParameters: GenerateParameters(maxTokens: 1_400, temperature: 0)
        )
        let content = try await session.respond(to: input.prompt)
        return try NovelRoleAnalysisCodec.decode(content: content, input: input, fallback: fallback)
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
