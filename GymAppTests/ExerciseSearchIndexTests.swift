import Foundation
import Testing
@testable import GymApp

// MARK: - Helpers

/// Builds a catalogue record the way the importer does, so the index under test sees exactly the
/// shape it sees in production.
private func makeExercise(
    id: String,
    name: String,
    bodyPart: BodyPart = .chest,
    equipment: Equipment = .barbell,
    target: Muscle = .pectorals,
    synergist: Muscle? = nil,
    secondary: [Muscle] = []
) -> Exercise {
    Exercise(
        id: id,
        name: name,
        bodyPart: bodyPart,
        equipment: equipment,
        target: target,
        synergist: synergist,
        secondaryMuscles: secondary,
        mediaID: "media-\(id)",
        thumbnailFileName: "\(id).jpg",
        animationFileName: "\(id).gif",
        attribution: "© test",
        createdAt: Date(timeIntervalSince1970: 0),
        metadata: ExerciseMetadataDeriver.derive(
            name: name,
            bodyPart: bodyPart,
            equipment: equipment,
            target: target,
            synergist: synergist,
            secondaryMuscles: secondary
        )
    )
}

private func index(_ exercises: [Exercise]) -> ExerciseSearchIndex {
    ExerciseSearchIndex(exercises: exercises)
}

// MARK: - Ranking

@Suite("Search ranking")
struct ExerciseSearchRankingTests {

    @Test("An exact name outranks a prefix, which outranks a substring")
    func exactBeatsPrefixBeatsSubstring() {
        let searchIndex = index([
            makeExercise(id: "sub", name: "barbell bench press"),
            makeExercise(id: "prefix", name: "bench press machine"),
            makeExercise(id: "exact", name: "bench press")
        ])
        #expect(searchIndex.search("bench press") == ["exact", "prefix", "sub"])
    }

    @Test("A single word ranks exact, then name prefix, then token prefix, then substring")
    func singleWordRankingLadder() {
        let searchIndex = index([
            makeExercise(id: "substring", name: "narrow grip pulldown"),
            makeExercise(id: "token", name: "barbell row"),
            makeExercise(id: "prefix", name: "rowing machine"),
            makeExercise(id: "exact", name: "row")
        ])
        #expect(searchIndex.search("row") == ["exact", "prefix", "token", "substring"])
    }

    @Test("A name match outranks a match on equipment")
    func nameBeatsEquipment() {
        let searchIndex = index([
            makeExercise(
                id: "equipment", name: "goblet squat",
                bodyPart: .upperLegs, equipment: .kettlebell, target: .quads
            ),
            makeExercise(
                id: "name", name: "kettlebell swing",
                bodyPart: .upperLegs, equipment: .kettlebell, target: .glutes
            )
        ])
        #expect(searchIndex.search("kettlebell") == ["name", "equipment"])
    }

    @Test("Ties on match quality are broken by how staple the movement is")
    func stapleScoreBreaksTies() {
        let cable = makeExercise(id: "cable", name: "fly cable", equipment: .cable)
        let band = makeExercise(id: "band", name: "fly band", equipment: .band)
        #expect(cable.metadata.stapleScore > band.metadata.stapleScore)
        #expect(index([band, cable]).search("fly") == ["cable", "band"])
    }

    @Test("Search never returns an id that is not in the index")
    func resultsAreDrawnFromTheIndex() {
        let exercises = [
            makeExercise(id: "a", name: "barbell bench press"),
            makeExercise(id: "b", name: "dumbbell bench press", equipment: .dumbbell)
        ]
        let results = index(exercises).search("bench")
        #expect(Set(results).isSubset(of: Set(exercises.map(\.id))))
        #expect(Set(results).count == results.count, "search returned a duplicate id")
    }

    @Test("The result limit is respected")
    func limitIsRespected() {
        let exercises = (0..<20).map { makeExercise(id: "\($0)", name: "press variation \($0)") }
        #expect(index(exercises).search("press", limit: 5).count == 5)
        #expect(index(exercises).search("press", limit: 0).isEmpty)
    }
}

// MARK: - Normalisation

@Suite("Search normalisation")
struct ExerciseSearchNormalisationTests {

    @Test("Case is ignored")
    func caseIsIgnored() {
        let searchIndex = index([makeExercise(id: "a", name: "Barbell Bench Press")])
        #expect(searchIndex.search("barbell bench press") == ["a"])
        #expect(searchIndex.search("BARBELL BENCH PRESS") == ["a"])
        #expect(searchIndex.search("BaRbElL bEnCh PrEsS") == ["a"])
    }

    @Test("Diacritics are ignored in both the query and the catalogue name")
    func diacriticsAreIgnored() {
        let searchIndex = index([makeExercise(id: "a", name: "Développé Couché")])
        #expect(searchIndex.search("developpe couche") == ["a"])
        #expect(searchIndex.search("Développé Couché") == ["a"])
        #expect(searchIndex.search("DEVELOPPE") == ["a"])
    }

    @Test("Punctuation collapses to word boundaries")
    func punctuationCollapses() {
        let searchIndex = index([makeExercise(id: "a", name: "3/4 sit-up", bodyPart: .waist, target: .abs)])
        #expect(searchIndex.search("sit up") == ["a"])
        #expect(searchIndex.search("sit-up") == ["a"])
    }

    @Test("The tokenizer normalises exactly what the index and the deriver both rely on")
    func tokenizerNormalisation() {
        #expect(ExerciseNameTokenizer.normalize("Développé Couché") == "developpe couche")
        #expect(ExerciseNameTokenizer.normalize("  3/4 SIT-UP  ") == "3 4 sit up")
        #expect(ExerciseNameTokenizer.tokens("3/4 sit-up") == ["3", "4", "sit", "up"])
        #expect(ExerciseNameTokenizer.paddedNormalized("row") == " row ")
        #expect(ExerciseNameTokenizer.normalize("") == "")
        #expect(ExerciseNameTokenizer.tokens("!!!").isEmpty)
    }
}

// MARK: - Query semantics

@Suite("Search query semantics")
struct ExerciseSearchQueryTests {

    private var multiWordCatalogue: [Exercise] {
        [
            makeExercise(id: "cable-incline", name: "cable incline fly", equipment: .cable),
            makeExercise(id: "cable-flat", name: "cable fly", equipment: .cable),
            makeExercise(id: "db-incline", name: "dumbbell incline fly", equipment: .dumbbell)
        ]
    }

    @Test("A multi-word query requires every word to match")
    func multiWordRequiresAllWords() {
        let results = index(multiWordCatalogue).search("cable incline")
        #expect(results == ["cable-incline"])
    }

    @Test("A word the catalogue does not contain removes the whole result")
    func oneUnmatchedWordExcludesTheExercise() {
        let results = index(multiWordCatalogue).search("cable incline barbell")
        #expect(results.isEmpty)
    }

    @Test("An empty query returns nothing")
    func emptyQueryReturnsNothing() {
        let searchIndex = index(multiWordCatalogue)
        #expect(searchIndex.search("").isEmpty)
        #expect(searchIndex.search("   ").isEmpty)
        #expect(searchIndex.search("!!!").isEmpty)
        #expect(searchIndex.search("\n\t").isEmpty)
    }

    @Test("A nonsense query returns nothing rather than everything")
    func nonsenseQueryReturnsNothing() {
        let searchIndex = index(multiWordCatalogue)
        #expect(searchIndex.search("zzqqxvwy").isEmpty)
        #expect(searchIndex.search("qwertyuiop asdfghjkl").isEmpty)
    }

    @Test("An index over an empty catalogue returns nothing for any query")
    func emptyCatalogueReturnsNothing() {
        let searchIndex = index([])
        #expect(searchIndex.search("bench press").isEmpty)
        #expect(searchIndex.search("").isEmpty)
    }

    @Test("A muscle, a piece of equipment and a body part are all searchable")
    func nonNameTermsAreSearchable() {
        let exercise = makeExercise(
            id: "a", name: "lever seated crunch",
            bodyPart: .waist, equipment: .leverageMachine, target: .abs, synergist: .obliques
        )
        let searchIndex = index([exercise])
        #expect(searchIndex.search("abs") == ["a"], "target muscle should be searchable")
        #expect(searchIndex.search("obliques") == ["a"], "synergist muscle should be searchable")
        #expect(searchIndex.search("leverage machine") == ["a"], "equipment should be searchable")
        #expect(searchIndex.search("waist") == ["a"], "body part should be searchable")
    }
}

// MARK: - Against the bundled catalogue

@Suite("Search over the bundled catalogue")
struct ExerciseSearchCatalogueTests {

    private static let searchIndex = ExerciseSearchIndex(exercises: ExerciseDatasetFixture.exercises)
    private static let byID = Dictionary(
        ExerciseDatasetFixture.exercises.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first }
    )

    private func results(_ query: String, limit: Int = 400) -> [Exercise] {
        Self.searchIndex.search(query, limit: limit).compactMap { Self.byID[$0] }
    }

    @Test("Typing an exercise's full name puts it first")
    func exactNameRanksFirst() {
        #expect(results("barbell bench press").first?.id == "0025")
        #expect(results("barbell full squat").first?.id == "0043")
        #expect(results("hanging leg raise").first?.id == "0472")
        #expect(results("jump rope").first?.id == "2612")
    }

    @Test("Case and diacritics make no difference to the bundled catalogue either")
    func caseAndDiacriticsDoNotChangeResults() {
        let plain = Self.searchIndex.search("barbell bench press")
        #expect(Self.searchIndex.search("BARBELL BENCH PRESS") == plain)
        #expect(Self.searchIndex.search("  barbell   bench   press  ") == plain)
        #expect(Self.searchIndex.search("bárbell bénch préss") == plain)
    }

    @Test("Searching a muscle returns exercises that train it")
    func muscleSearchReturnsRelevantResults() {
        let hamstrings = results("hamstrings")
        #expect(!hamstrings.isEmpty)
        let irrelevant = hamstrings.filter {
            !$0.allMuscles.contains(.hamstrings)
                && !ExerciseNameTokenizer.normalize($0.name).contains("hamstring")
        }
        #expect(irrelevant.isEmpty, "\(irrelevant.count) hamstring results train no hamstrings")
    }

    @Test("Searching a piece of equipment returns exercises that use it")
    func equipmentSearchReturnsRelevantResults() {
        let kettlebell = results("kettlebell")
        #expect(!kettlebell.isEmpty)
        let irrelevant = kettlebell.filter {
            $0.equipment != .kettlebell && !ExerciseNameTokenizer.normalize($0.name).contains("kettlebell")
        }
        #expect(irrelevant.isEmpty, "\(irrelevant.count) kettlebell results use no kettlebell")
    }

    @Test("Searching a body part returns exercises filed under it")
    func bodyPartSearchReturnsRelevantResults() {
        let cardio = results("cardio")
        #expect(!cardio.isEmpty)
        let irrelevant = cardio.filter {
            $0.bodyPart != .cardio
                && $0.target != .cardiovascularSystem
                && !ExerciseNameTokenizer.normalize($0.name).contains("cardio")
        }
        #expect(irrelevant.isEmpty, "\(irrelevant.count) cardio results are not cardio")

        #expect(!results("shoulders").isEmpty)
        #expect(!results("waist").isEmpty)
    }

    @Test("A multi-word query over the real catalogue keeps only exercises matching every word")
    func multiWordQueryOverTheCatalogue() {
        let matches = results("cable incline fly")
        #expect(!matches.isEmpty)
        for exercise in matches {
            let name = ExerciseNameTokenizer.normalize(exercise.name)
            for word in ["cable", "incline", "fly"] {
                let matchedSomewhere = name.contains(word)
                    || ExerciseNameTokenizer.normalize(exercise.equipment.rawValue).contains(word)
                    || ExerciseNameTokenizer.normalize(exercise.bodyPart.rawValue).contains(word)
                    || exercise.allMuscles.contains { ExerciseNameTokenizer.normalize($0.rawValue).contains(word) }
                    || exercise.metadata.substitutionTags.contains { $0.contains(word) }
                #expect(matchedSomewhere, "\(exercise.id) '\(exercise.name)' does not match '\(word)'")
            }
        }
    }

    @Test("An empty or nonsense query over the real catalogue returns nothing")
    func emptyAndNonsenseQueriesReturnNothing() {
        #expect(Self.searchIndex.search("").isEmpty)
        #expect(Self.searchIndex.search("     ").isEmpty)
        #expect(Self.searchIndex.search("qzxjvkwyb").isEmpty)
        #expect(Self.searchIndex.search("zzz qqq xxx").isEmpty)
    }

    @Test("Search results are unique and honour the requested limit")
    func resultsAreUniqueAndLimited() {
        let ids = Self.searchIndex.search("press", limit: 25)
        #expect(ids.count == 25)
        #expect(Set(ids).count == ids.count)
    }
}
