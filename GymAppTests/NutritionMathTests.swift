import Foundation
import Testing
@testable import GymApp

/// Tests for the value types the nutrition engines are built on: macro arithmetic, micronutrient
/// scaling that keeps "unknown" distinct from "zero", `FoodItem` portion maths, and the
/// locale-independent formatting and hashing helpers.
///
/// Specification: `docs/fragments/nutrition.md` (Shared helpers) and the doc comments on
/// `MacroNutrients`, `Micronutrients` and `FoodItem`.
@Suite("Nutrition portion and value-type maths")
struct NutritionMathTests {

    // MARK: - MacroNutrients arithmetic

    @Test("Adding two macro sets adds every field")
    func macroAdditionAddsEveryField() {
        let a = MacroNutrients(kilocalories: 250, proteinG: 20, carbsG: 30, fatG: 5)
        let b = MacroNutrients(kilocalories: 100, proteinG: 5, carbsG: 10, fatG: 2.5)
        let sum = a + b
        #expect(sum.kilocalories == 350)
        #expect(sum.proteinG == 25)
        #expect(sum.carbsG == 40)
        #expect(sum.fatG == 7.5)
    }

    @Test("Subtracting macro sets can legitimately go negative — a remainder is not a portion")
    func macroSubtractionMayGoNegative() {
        let target = MacroNutrients(kilocalories: 2_000, proteinG: 150, carbsG: 200, fatG: 60)
        let eaten = MacroNutrients(kilocalories: 2_300, proteinG: 180, carbsG: 210, fatG: 80)
        let remaining = target - eaten
        #expect(remaining.kilocalories == -300)
        #expect(remaining.proteinG == -30)
        #expect(remaining.carbsG == -10)
        #expect(remaining.fatG == -20)
    }

    @Test("Scaling a macro set scales every field")
    func macroScalingScalesEveryField() {
        let per100 = MacroNutrients(kilocalories: 165, proteinG: 31, carbsG: 0, fatG: 3.6)
        let portion = per100 * 1.5
        #expect(abs(portion.kilocalories - 247.5) < 0.0001)
        #expect(abs(portion.proteinG - 46.5) < 0.0001)
        #expect(portion.carbsG == 0)
        #expect(abs(portion.fatG - 5.4) < 0.0001)

        #expect(per100 * 0 == MacroNutrients.zero)
    }

    @Test("Adding zero is the identity, and zero is all zeroes")
    func zeroIsTheAdditiveIdentity() {
        let macros = MacroNutrients(kilocalories: 500, proteinG: 40, carbsG: 50, fatG: 15)
        #expect(macros + .zero == macros)
        #expect(MacroNutrients.zero.kilocalories == 0)
        #expect(MacroNutrients.zero.derivedKilocalories == 0)
    }

    @Test("Derived energy uses the 4/4/9 convention and ignores the stated calorie figure")
    func derivedEnergyUsesFourFourNine() {
        let macros = MacroNutrients(kilocalories: 9_999, proteinG: 30, carbsG: 40, fatG: 10)
        // 30·4 + 40·4 + 10·9 = 370
        #expect(macros.derivedKilocalories == 370)
    }

    @Test("Reducing a list of portions is the same as adding them one at a time")
    func summingPortionsIsAssociative() {
        let portions = [
            MacroNutrients(kilocalories: 248, proteinG: 46, carbsG: 0, fatG: 5.4),
            MacroNutrients(kilocalories: 260, proteinG: 5.4, carbsG: 56, fatG: 0.6),
            MacroNutrients(kilocalories: 51, proteinG: 4.2, carbsG: 10.5, fatG: 0.6)
        ]
        let reduced = portions.reduce(MacroNutrients.zero, +)
        let manual = portions[0] + portions[1] + portions[2]
        #expect(reduced == manual)
        #expect(abs(reduced.kilocalories - 559) < 0.0001)
    }

    // MARK: - Micronutrients: unknown is not zero

    @Test("Scaling keeps unknown nutrients unknown instead of turning them into zero")
    func scalingPreservesUnknownAsUnknown() {
        var micros = Micronutrients.unknown
        micros.fiberG = 3
        micros.sodiumMg = 400
        micros.ironMg = 0          // a genuine zero, which must survive as a zero

        let doubled = micros.scaled(by: 2)
        #expect(doubled.fiberG == 6)
        #expect(doubled.sodiumMg == 800)
        #expect(doubled.ironMg == 0, "a real zero must stay a zero, not become unknown")
        #expect(doubled.calciumMg == nil, "an unknown nutrient must not be invented as zero")
        #expect(doubled.vitaminCMg == nil)
    }

    @Test("Scaling by zero yields zeroes for known nutrients and still nil for unknown ones")
    func scalingByZeroKeepsTheKnownUnknownDistinction() {
        var micros = Micronutrients.unknown
        micros.fiberG = 8
        let scaled = micros.scaled(by: 0)
        #expect(scaled.fiberG == 0)
        #expect(scaled.potassiumMg == nil)
    }

    @Test("An entirely unknown profile stays entirely unknown however it is scaled")
    func unknownProfileStaysUnknown() {
        for factor in [0.0, 0.5, 1.0, 7.3] {
            let scaled = Micronutrients.unknown.scaled(by: factor)
            #expect(scaled == Micronutrients.unknown)
            for nutrient in Micronutrient.allCases {
                #expect(scaled[nutrient] == nil)
            }
        }
    }

    @Test("Adding two profiles keeps a nutrient unknown only when neither side knew it")
    func additionKeepsUnknownOnlyWhenBothSidesAreUnknown() {
        var lhs = Micronutrients.unknown
        lhs.fiberG = 3
        lhs.ironMg = 2

        var rhs = Micronutrients.unknown
        rhs.fiberG = 4
        rhs.calciumMg = 120

        let sum = lhs + rhs
        #expect(sum.fiberG == 7, "both sides knew fibre")
        // Documented behaviour: "a nutrient known in either operand stays known; unknown is treated
        // as a contribution of zero". So an unknown iron on the right does not erase the known 2 mg
        // on the left, and it is not itself invented as a value.
        #expect(sum.ironMg == 2)
        #expect(sum.calciumMg == 120)
        #expect(sum.vitaminCMg == nil, "neither side knew vitamin C, so the sum must not either")
        #expect(sum.sodiumMg == nil)
    }

    @Test("Adding the unknown profile changes nothing")
    func unknownIsTheAdditiveIdentityForKnownValues() {
        var micros = Micronutrients.unknown
        micros.fiberG = 5
        micros.zincMg = 1.2
        #expect(micros + .unknown == micros)
        #expect(Micronutrients.unknown + .unknown == Micronutrients.unknown)
    }

    @Test("The subscript reads and writes every nutrient the enum names")
    func subscriptCoversEveryNutrient() {
        for nutrient in Micronutrient.allCases {
            var micros = Micronutrients.unknown
            #expect(micros[nutrient] == nil)
            micros[nutrient] = 42
            #expect(micros[nutrient] == 42)
            micros[nutrient] = nil
            #expect(micros[nutrient] == nil)
        }
    }

    @Test("Summing a plate's micronutrients keeps the nutrients nobody recorded unknown")
    func summingAPlateKeepsGapsUnknown() {
        var chicken = Micronutrients.unknown
        chicken.sodiumMg = 74
        var rice = Micronutrients.unknown
        rice.fiberG = 0.4

        let plate = chicken.scaled(by: 1.5) + rice.scaled(by: 2)
        #expect(plate.sodiumMg == 111)
        #expect(abs((plate.fiberG ?? 0) - 0.8) < 0.0001)
        #expect(plate.calciumMg == nil)
    }

    // MARK: - FoodItem portion maths

    private static func chickenBreast() -> FoodItem {
        let food = FoodItem()
        food.name = "Chicken breast"
        food.kilocaloriesPer100 = 165
        food.proteinGPer100 = 31
        food.carbsGPer100 = 0
        food.fatGPer100 = 3.6
        var micros = Micronutrients.unknown
        micros.sodiumMg = 74
        food.micronutrientsPer100 = micros
        return food
    }

    @Test("Grams scale the per-100 g basis directly")
    func gramsScaleTheBasis() {
        let food = Self.chickenBreast()
        let macros = food.macros(forQuantity: 250, unit: .grams)
        #expect(abs(macros.kilocalories - 412.5) < 0.0001)
        #expect(abs(macros.proteinG - 77.5) < 0.0001)
        #expect(macros.carbsG == 0)
        #expect(abs(macros.fatG - 9) < 0.0001)
    }

    @Test("Exactly 100 g returns the stored per-100 g figures")
    func oneHundredGramsIsTheIdentity() {
        let food = Self.chickenBreast()
        #expect(food.macros(forQuantity: 100, unit: .grams) == food.macrosPer100)
    }

    @Test("A zero quantity returns zero macros rather than the per-100 g basis")
    func zeroQuantityReturnsZero() {
        let food = Self.chickenBreast()
        let macros = food.macros(forQuantity: 0, unit: .grams)
        #expect(macros == MacroNutrients.zero)
    }

    @Test("Millilitres use the same basis as grams")
    func millilitresUseTheSameBasis() {
        let milk = FoodItem()
        milk.name = "Milk"
        milk.basisUnit = .milliliters
        milk.kilocaloriesPer100 = 42
        milk.proteinGPer100 = 3.4
        milk.carbsGPer100 = 5
        milk.fatGPer100 = 1
        let macros = milk.macros(forQuantity: 250, unit: .milliliters)
        #expect(abs(macros.kilocalories - 105) < 0.0001)
        #expect(abs(macros.proteinG - 8.5) < 0.0001)
    }

    @Test("Pieces are converted through gramsPerPiece")
    func piecesUseGramsPerPiece() {
        let egg = FoodItem()
        egg.name = "Egg"
        egg.kilocaloriesPer100 = 155
        egg.proteinGPer100 = 13
        egg.carbsGPer100 = 1.1
        egg.fatGPer100 = 11
        egg.gramsPerPiece = 50

        #expect(egg.basisQuantity(for: 2, unit: .piece) == 100)
        let two = egg.macros(forQuantity: 2, unit: .piece)
        #expect(abs(two.kilocalories - 155) < 0.0001)
        #expect(abs(two.proteinG - 13) < 0.0001)

        let three = egg.macros(forQuantity: 3, unit: .piece)
        #expect(abs(three.kilocalories - 232.5) < 0.0001)
    }

    @Test("A food with no gramsPerPiece falls back to 100 g a piece rather than to zero")
    func missingGramsPerPieceFallsBackToOneHundred() {
        let food = Self.chickenBreast()
        #expect(food.gramsPerPiece == nil)
        #expect(food.basisQuantity(for: 2, unit: .piece) == 200)
        #expect(food.macros(forQuantity: 1, unit: .piece) == food.macrosPer100)
    }

    @Test("A named serving is converted through its own gramsPerServing")
    func namedServingsUseTheirOwnWeight() {
        let bread = FoodItem()
        bread.name = "Bread"
        bread.kilocaloriesPer100 = 265
        bread.proteinGPer100 = 9
        bread.carbsGPer100 = 49
        bread.fatGPer100 = 3.2
        bread.servings = [
            FoodServing(name: "1 slice", gramsPerServing: 28),
            FoodServing(name: "1 thick slice", gramsPerServing: 45)
        ]

        #expect(bread.basisQuantity(for: 2, unit: .serving, servingIndex: 0) == 56)
        #expect(bread.basisQuantity(for: 1, unit: .serving, servingIndex: 1) == 45)

        let twoSlices = bread.macros(forQuantity: 2, unit: .serving, servingIndex: 0)
        #expect(abs(twoSlices.kilocalories - 148.4) < 0.0001)
        #expect(abs(twoSlices.carbsG - 27.44) < 0.0001)
    }

    @Test("No serving index means the first serving")
    func missingServingIndexUsesTheFirstServing() {
        let bread = FoodItem()
        bread.kilocaloriesPer100 = 265
        bread.servings = [
            FoodServing(name: "1 slice", gramsPerServing: 28),
            FoodServing(name: "1 thick slice", gramsPerServing: 45)
        ]
        #expect(bread.basisQuantity(for: 1, unit: .serving) == 28)
    }

    @Test("An out-of-range serving index falls back to the first serving rather than crashing")
    func outOfRangeServingIndexFallsBack() {
        let bread = FoodItem()
        bread.kilocaloriesPer100 = 265
        bread.servings = [FoodServing(name: "1 slice", gramsPerServing: 28)]
        #expect(bread.basisQuantity(for: 1, unit: .serving, servingIndex: 9) == 28)
        #expect(bread.basisQuantity(for: 1, unit: .serving, servingIndex: -1) == 28)
    }

    @Test("A food with no servings at all falls back to 100 g")
    func noServingsFallsBackToOneHundredGrams() {
        let food = Self.chickenBreast()
        #expect(food.servings.isEmpty)
        #expect(food.basisQuantity(for: 1, unit: .serving) == 100)
        #expect(food.macros(forQuantity: 1, unit: .serving) == food.macrosPer100)
    }

    @Test("Micronutrients follow the same portion maths and keep their gaps unknown")
    func micronutrientsFollowThePortionMaths() {
        let food = Self.chickenBreast()
        let micros = food.micronutrients(forQuantity: 200, unit: .grams)
        #expect(micros.sodiumMg == 148)
        #expect(micros.ironMg == nil, "a nutrient the food never carried stays unknown at any portion")
    }

    @Test("A serving unit knows whether it is a mass or a count")
    func servingUnitClassification() {
        #expect(ServingUnit.grams.isMassOrVolume)
        #expect(ServingUnit.milliliters.isMassOrVolume)
        #expect(!ServingUnit.piece.isMassOrVolume)
        #expect(!ServingUnit.serving.isMassOrVolume)
    }

    // MARK: - Clamping helper

    @Test("Clamping bounds a value, and an inverted range collapses to the lower bound")
    func clampBehaviour() {
        #expect(nutritionClamp(5, 0, 10) == 5)
        #expect(nutritionClamp(-3, 0, 10) == 0)
        #expect(nutritionClamp(30, 0, 10) == 10)
        #expect(nutritionClamp(5, 10, 0) == 10, "an inverted range collapses to the lower bound")
        #expect(nutritionClamp(5, 7, 7) == 7)
    }

    @Test("Clamping a non-finite value returns the lower bound instead of propagating NaN")
    func clampRejectsNonFiniteInput() {
        #expect(nutritionClamp(.nan, 1, 10) == 1)
        #expect(nutritionClamp(.infinity, 1, 10) == 1)
        #expect(nutritionClamp(-.infinity, 1, 10) == 1)
        #expect(nutritionClamp01(.nan) == 0)
        #expect(nutritionClamp01(1.4) == 1)
        #expect(nutritionClamp01(-0.4) == 0)
    }

    // MARK: - Formatting

    @Test("Formatting is locale-independent and rounds as documented")
    func formattingIsPredictable() {
        #expect(NutritionFormat.whole(1_849.6) == "1850")
        #expect(NutritionFormat.whole(-12.4) == "-12")
        #expect(NutritionFormat.oneDecimal(0.44) == "0.4")
        #expect(NutritionFormat.twoDecimals(1.8549) == "1.85")
        #expect(NutritionFormat.percent(0.27) == "27%")
        #expect(NutritionFormat.percent(-0.05) == "-5%")
    }

    @Test("A signed rate that rounds to zero prints as 0.0, never as -0.0")
    func signedFormattingNeverPrintsNegativeZero() {
        #expect(NutritionFormat.signedOneDecimal(-0.03) == "0.0")
        #expect(NutritionFormat.signedOneDecimal(0.04) == "0.0")
        #expect(NutritionFormat.signedOneDecimal(0.44) == "+0.4")
        #expect(NutritionFormat.signedOneDecimal(-0.44) == "-0.4")
        #expect(NutritionFormat.signedOneDecimal(0) == "0.0")
    }

    @Test("Non-finite and absurd values are formatted rather than trapping")
    func formattingSaturatesInsteadOfTrapping() {
        #expect(NutritionFormat.whole(.nan) == "0")
        #expect(NutritionFormat.whole(.infinity) == "0")
        #expect(NutritionFormat.oneDecimal(.nan) == "0.0")
        #expect(NutritionFormat.twoDecimals(.nan) == "0.00")
        #expect(NutritionFormat.percent(.nan) == "0%")
        #expect(NutritionFormat.signedOneDecimal(.nan) == "0.0")

        // `Int(_: Double)` traps on a value this large; the formatter must saturate instead.
        let enormous = NutritionFormat.whole(.greatestFiniteMagnitude)
        #expect(!enormous.isEmpty)
        #expect(NutritionFormat.percent(1e300).isEmpty == false)
    }

    // MARK: - Deterministic ids

    @Test("The same signature always produces the same id, and different ones differ")
    func deterministicIDsAreStable() {
        let first = DeterministicID.make(from: "combo:cat-1@150|cat-7@200")
        let second = DeterministicID.make(from: "combo:cat-1@150|cat-7@200")
        #expect(first == second)
        #expect(DeterministicID.make(from: "combo:cat-1@155|cat-7@200") != first)
        #expect(DeterministicID.make(from: "") == DeterministicID.make(from: ""))
    }

    @Test("A deterministic id is a well-formed version 4 UUID")
    func deterministicIDsAreWellFormed() {
        for signature in ["", "a", "saved:one", "recipe:two@2", "a much longer signature 🍎"] {
            let uuid = DeterministicID.make(from: signature)
            let bytes = withUnsafeBytes(of: uuid.uuid) { Array($0) }
            #expect(bytes[6] & 0xf0 == 0x40, "\(signature) produced version nibble \(bytes[6] >> 4)")
            #expect(bytes[8] & 0xc0 == 0x80, "\(signature) produced a bad variant")
        }
    }

    // MARK: - Profile snapshot helpers

    @Test("Forbidden tags merge diet, allergens, intolerances and personal exclusions, lower-cased")
    func forbiddenTagsMergeEverySource() {
        var profile = NutritionProfileSnapshot()
        profile.dietType = .vegetarian
        profile.allergenTags = ["Peanut"]
        profile.intoleranceTags = ["LACTOSE"]
        profile.excludedFoodTags = ["Offal"]

        let forbidden = profile.forbiddenFoodTags
        #expect(forbidden.contains("meat"))
        #expect(forbidden.contains("fish"))
        #expect(forbidden.contains("peanut"))
        #expect(forbidden.contains("lactose"))
        #expect(forbidden.contains("offal"))
        #expect(!forbidden.contains("Peanut"), "tags must be normalised to lower case")
    }

    @Test("Energy shares renormalise over the slots the user actually eats")
    func energySharesRenormaliseOverActiveSlots() {
        var fourMeals = NutritionProfileSnapshot()
        fourMeals.mealsPerDay = 4
        let fourTotal = MealSlot.allCases.reduce(0) { $0 + fourMeals.energyShare(of: $1) }
        #expect(abs(fourTotal - 1) < 0.0001)
        #expect(abs(fourMeals.energyShare(of: .lunch) - 0.35) < 0.0001)

        var threeMeals = NutritionProfileSnapshot()
        threeMeals.mealsPerDay = 3
        #expect(threeMeals.activeSlots == [.breakfast, .lunch, .dinner])
        let threeTotal = threeMeals.activeSlots.reduce(0) { $0 + threeMeals.energyShare(of: $1) }
        #expect(abs(threeTotal - 1) < 0.0001, "the snack share must be redistributed, not dropped")
        #expect(
            threeMeals.energyShare(of: .lunch) > fourMeals.energyShare(of: .lunch),
            "lunch should carry more of the day when there are no snacks"
        )
    }

    @Test("A snack asked for outside the user's pattern still gets a share rather than zero")
    func aSnackOutsideThePatternStillGetsAShare() {
        var threeMeals = NutritionProfileSnapshot()
        threeMeals.mealsPerDay = 3
        #expect(threeMeals.energyShare(of: .snacks) > 0)
    }

    @Test("Body-mass index is nil rather than absurd when the height on file is implausible")
    func bodyMassIndexRefusesImplausibleHeights() {
        var profile = NutritionProfileSnapshot()
        profile.heightCm = 180
        profile.weightKg = 81
        #expect(abs((profile.bodyMassIndex ?? 0) - 25) < 0.001)

        profile.heightCm = 0
        #expect(profile.bodyMassIndex == nil)
        profile.heightCm = 400
        #expect(profile.bodyMassIndex == nil)
        profile.heightCm = 180
        profile.weightKg = 5
        #expect(profile.bodyMassIndex == nil)
    }

    @Test("The primary goal is the first one, falling back to general fitness for an empty list")
    func primaryGoalFallsBackSafely() {
        var profile = NutritionProfileSnapshot()
        profile.goals = []
        #expect(profile.primaryGoal == .generalFitness)
        profile.goals = [.loseFat, .buildMuscle]
        #expect(profile.primaryGoal == .loseFat)
    }
}
