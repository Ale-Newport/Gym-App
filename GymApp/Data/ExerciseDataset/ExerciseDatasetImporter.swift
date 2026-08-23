import Foundation

/// Errors raised while ingesting the bundled dataset.
enum ExerciseDatasetError: LocalizedError {
    case manifestMissing
    case coreDataMissing
    case decodingFailed(String)
    case countMismatch(expected: Int, found: Int)

    var errorDescription: String? {
        switch self {
        case .manifestMissing: "The exercise dataset manifest is missing from the app bundle."
        case .coreDataMissing: "The exercise dataset is missing from the app bundle."
        case .decodingFailed(let detail): "The exercise dataset could not be read: \(detail)"
        case .countMismatch(let expected, let found):
            "The exercise dataset is incomplete: expected \(expected) records but found \(found)."
        }
    }
}

/// Metadata about the bundled dataset, written by `Tools/prepare_dataset.py`.
struct ExerciseDatasetManifest: Codable, Sendable {
    let schemaVersion: Int
    let datasetVersion: String
    let generatedAt: String
    let sourceRepository: String
    let sourceChecksum: String
    let exerciseCount: Int
    let languages: [String]
    let mediaAttribution: String
    let mediaLicense: String
    let mediaResolution: String
}

/// The on-disk shape of one record in `exercises.core.json`.
private struct RawExercise: Decodable {
    let id: String
    let name: String
    let bodyPart: String
    let equipment: String
    let target: String
    let muscleGroup: String
    let secondaryMuscles: [String]
    let mediaId: String
    let thumbnail: String
    let animation: String
    let attribution: String
    let createdAt: String
}

/// Reads the bundled dataset, validates it, maps it onto domain types and derives training
/// metadata.
///
/// The importer is **idempotent** and **versioned**: it reads `dataset-manifest.json`, and callers
/// compare `datasetVersion` against what they last ingested to decide whether anything changed.
/// Because the catalogue is immutable reference data held in memory rather than rows in the user's
/// database, a dataset upgrade can never touch history or preferences — those reference exercises
/// by their stable dataset id.
///
/// A single defective record is dropped and logged rather than failing the whole import, so one bad
/// row in a future dataset revision cannot brick the app.
struct ExerciseDatasetImporter {
    let bundle: Bundle

    init(bundle: Bundle = .main) {
        self.bundle = bundle
    }

    /// Locates the dataset directory inside the bundle. `prepare_dataset.py` writes it as a folder
    /// reference, so the subdirectory structure survives into the built product.
    private func datasetURL(_ component: String) -> URL? {
        if let url = bundle.url(forResource: component, withExtension: nil, subdirectory: "ExerciseDataset") {
            return url
        }
        return bundle.url(forResource: component, withExtension: nil)
    }

    func loadManifest() throws -> ExerciseDatasetManifest {
        guard let url = datasetURL("dataset-manifest.json"),
              let data = try? Data(contentsOf: url) else {
            throw ExerciseDatasetError.manifestMissing
        }
        do {
            return try JSONDecoder().decode(ExerciseDatasetManifest.self, from: data)
        } catch {
            throw ExerciseDatasetError.decodingFailed(String(describing: error))
        }
    }

    /// Decodes, normalises and enriches every record. Runs off the main actor; the caller awaits it
    /// during launch so the UI never blocks on JSON parsing.
    func loadExercises(expecting manifest: ExerciseDatasetManifest) throws -> [Exercise] {
        guard let url = datasetURL("exercises.core.json"),
              let data = try? Data(contentsOf: url) else {
            throw ExerciseDatasetError.coreDataMissing
        }

        let raws: [RawExercise]
        do {
            raws = try JSONDecoder().decode([RawExercise].self, from: data)
        } catch {
            throw ExerciseDatasetError.decodingFailed(String(describing: error))
        }

        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let plainFormatter = ISO8601DateFormatter()

        var seenIDs = Set<String>()
        var exercises: [Exercise] = []
        exercises.reserveCapacity(raws.count)

        for raw in raws {
            guard !raw.id.isEmpty, !raw.name.isEmpty else {
                AppLog.catalog.error("Skipping record with an empty id or name")
                continue
            }
            guard seenIDs.insert(raw.id).inserted else {
                AppLog.catalog.error("Skipping duplicate exercise id \(raw.id, privacy: .public)")
                continue
            }
            guard let target = Muscle(datasetValue: raw.target) else {
                AppLog.catalog.error("Skipping \(raw.id, privacy: .public): unknown target '\(raw.target, privacy: .public)'")
                continue
            }

            let bodyPart = BodyPart(datasetValue: raw.bodyPart)
            let equipment = Equipment(datasetValue: raw.equipment)
            let synergist = Muscle(datasetValue: raw.muscleGroup)

            var seenSecondary: Set<Muscle> = [target]
            if let synergist { seenSecondary.insert(synergist) }
            let secondary = raw.secondaryMuscles.compactMap { Muscle(datasetValue: $0) }
                .filter { seenSecondary.insert($0).inserted }

            let metadata = ExerciseMetadataDeriver.derive(
                name: raw.name,
                bodyPart: bodyPart,
                equipment: equipment,
                target: target,
                synergist: synergist,
                secondaryMuscles: secondary
            )

            let created = formatter.date(from: raw.createdAt)
                ?? plainFormatter.date(from: raw.createdAt)
                ?? Date(timeIntervalSince1970: 0)

            exercises.append(
                Exercise(
                    id: raw.id,
                    name: raw.name,
                    bodyPart: bodyPart,
                    equipment: equipment,
                    target: target,
                    synergist: synergist,
                    secondaryMuscles: secondary,
                    mediaID: raw.mediaId,
                    thumbnailFileName: raw.thumbnail,
                    animationFileName: raw.animation,
                    attribution: raw.attribution,
                    createdAt: created,
                    metadata: metadata
                )
            )
        }

        if exercises.count != manifest.exerciseCount {
            AppLog.catalog.error(
                "Dataset count mismatch: manifest says \(manifest.exerciseCount) but \(exercises.count) records loaded"
            )
        }
        guard !exercises.isEmpty else {
            throw ExerciseDatasetError.countMismatch(expected: manifest.exerciseCount, found: 0)
        }
        return exercises
    }
}
