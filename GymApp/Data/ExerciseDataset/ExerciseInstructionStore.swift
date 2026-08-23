import Foundation

/// Serves per-language exercise instructions.
///
/// `prepare_dataset.py` splits the upstream dataset's ten-language instruction blob into ten files.
/// Only the language actually being read is parsed, and only on first use, which keeps ~7 MB of
/// text out of memory. Switching language loads the new file and drops the old one.
actor ExerciseInstructionStore {
    static let shared = ExerciseInstructionStore()

    private var cache: [AppLanguage: [String: [String]]] = [:]
    private let bundle: Bundle

    init(bundle: Bundle = .main) {
        self.bundle = bundle
    }

    /// Instruction steps for one exercise, falling back to English when a language file is absent.
    func steps(for exerciseID: String, language: AppLanguage) async -> [String] {
        if let steps = await table(for: language)[exerciseID], !steps.isEmpty { return steps }
        if language != .english, let fallback = await table(for: .english)[exerciseID] { return fallback }
        return []
    }

    /// Preloads a language so the first exercise detail screen opens without a hop.
    func preload(_ language: AppLanguage) async {
        _ = await table(for: language)
    }

    /// Frees every language table except `keep`. Called on memory pressure.
    func purge(keeping keep: AppLanguage?) {
        cache = cache.filter { $0.key == keep }
    }

    private func table(for language: AppLanguage) async -> [String: [String]] {
        if let cached = cache[language] { return cached }

        let fileName = "instructions.\(language.datasetCode).json"
        let url = bundle.url(forResource: fileName, withExtension: nil, subdirectory: "ExerciseDataset/instructions")
            ?? bundle.url(forResource: fileName, withExtension: nil, subdirectory: "instructions")
            ?? bundle.url(forResource: fileName, withExtension: nil)

        guard let url, let data = try? Data(contentsOf: url) else {
            AppLog.catalog.error("Missing instruction file \(fileName, privacy: .public)")
            cache[language] = [:]
            return [:]
        }

        do {
            let table = try JSONDecoder().decode([String: [String]].self, from: data)
            cache[language] = table
            return table
        } catch {
            AppLog.catalog.error("Failed to decode \(fileName, privacy: .public): \(String(describing: error), privacy: .public)")
            cache[language] = [:]
            return [:]
        }
    }
}
