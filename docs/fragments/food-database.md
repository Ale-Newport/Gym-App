# Food database and food data providers

Everything the app knows about food arrives through one of three doors: the database bundled in
the app, Open Food Facts, or the user typing it in. This fragment covers the first two and the
machinery that keeps them interchangeable.

## The bundled database

`GymApp/Resources/FoodDatabase/foods.json` holds **594 records**, each stated per 100 g — or per
100 ml where `basisUnit` is `"ml"`, which covers 56 drinks and liquid staples. Coverage spans
meats and poultry, fish and seafood, eggs and dairy, legumes and meat alternatives, grains,
breads and pasta, nuts, seeds, oils and fats, fruit, vegetables, tubers, cooked staples (rice,
pasta, oats, potatoes), everyday prepared dishes, protein powders and supplements, drinks, and a
modest set of everyday packaged categories described generically. **No brand names or trademarks
appear anywhere in the file**; a packaged category is described by what it is ("Digestive
biscuit", "Energy drink, sugar free"), never by who makes it.

### Provenance

Values are taken from **USDA FoodData Central — SR Legacy and Foundation Foods**. These are works
of the US Government and are in the public domain, which is why they can be shipped inside the app
with nothing more than an attribution. The attribution is recorded in
`food-database-manifest.json`, stamped onto every imported row as `FoodItem.attribution`, and
shown to the user under the key `food.database.attribution`.

A small number of generic composite dishes — lasagne, chicken curry, a chicken wrap — have no
single USDA record and are estimated from their ingredient lists instead. The manifest says so.

### Unknown is not zero

`Micronutrients` stores every nutrient as an `Optional`, and the JSON honours that: **a
micronutrient key is emitted only when there is a defensible value for it, and omitted
otherwise.** Nothing is ever filled in with a plausible-looking guess. This is a product
requirement rather than a stylistic choice — conflating "not measured" with "contains none" would
let the app tell somebody they are deficient in a nutrient the data never measured.

Coverage, by way of illustration: fibre and sodium on all 594 records, potassium on 573, sugars on
389, saturated fat on 333, cholesterol on 172, iron on 150, vitamin C on 137, and progressively
fewer for the trace vitamins, which are populated mainly for the curated everyday foods.

### Energy consistency check

Every record must have energy that agrees with its macros. The check runs in three tiers and
**594 of 594 records pass**:

| Tier | Rule | Records |
| --- | --- | --- |
| 1 | Atwater `protein × 4 + carbs × 4 + fat × 9` within **12%** of the stated kcal | 512 |
| 2 | The EU labelling calculation, crediting fibre at 2 kcal/g instead of 4 | 61 |
| 3 | Absolute error ≤ **15 kcal per 100 g** | 21 |

Tier 2 exists because USDA carbohydrate is *by difference* and therefore already includes fibre,
so plain Atwater systematically overstates fibrous plant foods. Crediting fibre at 2 kcal/g is
exactly the calculation EU Regulation 1169/2011, Annex XIV prescribes: energy =
`protein × 4 + (carbs − fibre) × 4 + fibre × 2 + fat × 9`. Raw broccoli, for example, is 41 kcal
under plain Atwater against a stated 34, and 36 kcal once fibre is credited correctly.

Tier 3 catches very low-energy plant foods — lemons, limes, cucumber, mushrooms, watercress, bean
sprouts — where USDA applies FAO *specific* Atwater factors and discounts organic acids such as
citric acid. The relative error looks alarming and the absolute error is trivial: at most 15 kcal
per 100 g, on foods logged in tens of grams. The bound still catches real data errors, because a
misplaced macro is worth far more than 15 kcal.

Two categories of energy sit outside the macros entirely and are handled explicitly rather than
being waved through:

- **Alcohol.** Ethanol supplies 7 kcal/g and no macronutrient field carries it. The seven
  alcoholic drinks in the database (lager, ale, cider, red and white wine, sparkling wine,
  spirits) are checked against `macros + ethanol × 7` using their known ABV. Their stored macros
  are correct; the app simply shows kcal that its own macro arithmetic cannot reproduce, which is
  how every food tracker handles alcohol.
- **Organic acids.** Balsamic and cider vinegar derive most of their energy from acetic acid at
  roughly 3.5 kcal/g, and are checked the same way.

A handful of USDA records were **deliberately excluded** because they cannot pass any honest
version of this check: wheat bran, oat bran and unsweetened cocoa powder, whose
carbohydrate-by-difference includes large unavailable fractions that USDA discounts through
specific factors the raw macros do not expose. Shipping them would mean shipping numbers that
contradict themselves.

### Structural checks

Alongside energy, every record is checked for: a valid `basisUnit`; no negative values; macros
summing to no more than 100 g per 100 g; fibre never exceeding carbohydrate; and no non-positive
serving size. All 594 pass.

### Tags

Three closed vocabularies, declared once in `FoodTagVocabulary` and enforced by the generator:

- `dietaryTags` — exactly `meat`, `poultry`, `fish`, `seafood`, `dairy`, `egg`, `honey`. This is
  precisely the set `DietType.excludedTags` matches against; anything else would silently fail to
  filter. Coverage leaves 472 foods for a vegetarian, 365 for a vegan and 521 for a pescatarian.
- `allergenTags` — `gluten`, `nuts`, `peanut`, `soy`, `shellfish`, `sesame`.
- `roleTags` — the vocabulary `MealRecommendationEngine` reads.

Role tags are **derived, not hand-typed**, so they cannot drift. The thresholds are regulatory
definitions rather than invented numbers, and `FoodRoleTagDeriver` applies the identical rules to
remote records so an imported tuna tin behaves like the bundled one:

| Tag | Rule | Basis |
| --- | --- | --- |
| `protein_source` | ≥ 10 g protein per 100 g **and** protein ≥ 25% of energy | EU Reg. 1924/2006 sets "source of protein" at 12% of energy and "high protein" at 20%; raised to 25% because in a training app the label should mean something stronger than yogurt-coated cereal |
| `carb_source` | ≥ 20 g carbs **and** carbs ≥ 45% of energy | Practical threshold: identifies foods eaten *for* their carbohydrate |
| `fat_source` | ≥ 15 g fat **and** fat ≥ 50% of energy | As above |
| `high_fiber` | ≥ 6 g fibre per 100 g | EU Reg. 1924/2006 "high fibre" |
| `lean` | a protein source with ≤ 10 g fat and ≤ 4.5 g saturated fat per 100 g | USDA labelling definition of "lean" |
| `drink` | `basisUnit == "ml"` | — |

`vegetable`, `fruit`, `supplement`, `budget`, `quick` and the four meal-slot tags are assigned per
record, because no formula can tell you that porridge is breakfast.

### Localisation

244 records — the everyday foods a typical user logs most often — carry a `nameKey` and ship
translated; the remainder show their English name. Portions use a **closed vocabulary of 62
serving names** (`food.serving.tbsp`, `food.serving.fillet`, …) rather than free text, so every
built-in portion is translatable without translating six hundred bespoke strings.

## Search

`FoodSearchIndex` follows `ExerciseSearchIndex` deliberately, so search behaves identically in
both halves of the app: everything is pre-normalised at load (lowercased, diacritics stripped,
punctuation collapsed), and a query is a linear scan over compact strings with no per-keystroke
allocation. 200 searches over the full catalogue take ~165 ms in a release build, i.e. **under a
millisecond per keystroke**.

Every word of a multi-word query must match somewhere. Match quality is ranked
`exactName → namePrefix → nameTokenPrefix → nameSubstring → synonym → tag`, and the result takes
the *worst* rank across the query's words. Ties break on prominence, then on name length, then on
catalogue id so ordering is fully deterministic.

**Prominence** is the tie-breaker: `+1.0` for a curated `nameKey`, `+0.2` for having named
portions, `+0.1` for a budget staple. The curated set is the best available proxy for "what people
actually log", which is exactly what a tie-breaker wants.

Two fallbacks fire only when a word fails outright, and both were added to fix real misses:

- **Singularisation** — "eggs" → "egg", "tomatoes" → "tomato". Both `-es` candidates are tried,
  since the suffix is ambiguous ("grapes" drops one character, "tomatoes" two). A stemmer would be
  overkill for 600 fixed English names.
- **Synonyms** — a deliberately small table covering cooking states (the catalogue says "boiled"
  where users type "cooked") and British/American names (`courgette`/`zucchini`,
  `mince`/`ground`, `prawns`/`shrimp`, `tinned`/`canned`, `chips`/`crisps`/`fries`). Every entry
  is a rule somebody must maintain, and a broad synonym list makes search vaguer, not better.

Portion names are indexed as tags, so "cod fillet" and "chicken breast" find what the user means
even when the catalogue calls the portion a serving.

## Providers

```
protocol FoodDataProvider: Sendable {
    var identifier: String { get }
    var isRemote: Bool { get }
    func search(_ query: String, limit: Int) async throws -> [FoodSearchResult]
    func food(withBarcode barcode: String) async throws -> FoodSearchResult?
    func food(withIdentifier identifier: String) async throws -> FoodSearchResult?
}
```

Providers return **values**, never model objects. Only a food the user actually logs becomes a
`FoodItem`. `CompositeFoodDataProvider` runs local providers first, then races the remote ones
against a 6 s budget, merges, and de-duplicates: same barcode, or same folded name with energy
agreeing to within 5 kcal. Any provider that fails is dropped with a logged reason rather than
taking the search down with it.

### LocalFoodDatabaseProvider

**This is the provider that makes the app work offline.** It loads `foods.json` once, lazily, off
the main actor via a detached task whose handle is shared so concurrent callers pay for one
decode, and answers from memory afterwards. It holds no barcodes — the bundled database describes
generic foods, not packaged products — so `food(withBarcode:)` returns `nil` and lets the
composite fall through to a remote lookup. A failed load resets to `idle` so a later caller can
retry.

### OpenFoodFactsProvider

Real `URLSession` calls against the public Open Food Facts API. `/api/v2/product/<barcode>.json`
for barcodes, `/cgi/search.pl` for text search. **No API keys exist anywhere** — their read API is
open, which is also why the whole provider could be deleted without touching anything else.

- **User-Agent.** Their terms require an identifying agent:
  `Forge/<version> (iOS <major>.<minor>; +<contact>)`. Sending a generic agent is grounds for
  being blocked.
- **Timeouts.** 8 s per request. Long enough for a slow mobile connection, short enough that a
  scan going nowhere returns to the local fallback before the user gives up.
- **Cancellation.** `Task.isCancelled` is checked before each request and after each response;
  `URLError.cancelled` maps to `FoodProviderError.cancelled`.
- **Rate limiting.** Client-side rolling one-minute windows at their published limits: 100 product
  reads and 10 searches per minute. Being throttled server-side costs the user a failed search;
  refusing locally costs them nothing, because the bundled results are already in hand.
- **Cache.** In-memory, keyed by request: 30 min for products, 10 min for searches, 5 min for
  misses (so re-scanning an unknown packet does not refire a doomed request), capped at 200
  entries with oldest-first eviction. The clock is injected, so expiry and rate limiting are
  deterministic under test.
- **Every failure is non-fatal** and maps onto `FoodProviderError`.

Their nutriment fields are the awkward part, and the mapper is built around it:

- Values arrive as numbers *or* strings, including `"12,5"` with a comma decimal separator, `""`
  and `null`. `LooseNumber` accepts all of them and yields `nil` rather than throwing, so one bad
  field cannot lose the whole product.
- Per-100 keys vary. `*_100g` is preferred; failing that, `*_serving` rescaled by
  `serving_quantity`.
- Energy: `energy-kcal_100g`, else `energy-kj_100g / 4.184`, else `energy_100g / 4.184` (their
  generic field is kilojoules), else Atwater from the macros.
- **Minerals and vitamins are stored in grams** in the `_100g` fields, so each is scaled to the
  unit `Micronutrients` uses — ×1000 to mg, ×1 000 000 to µg — and each carries a plausibility
  ceiling, because a hundredfold error is common when a contributor types milligrams into a grams
  field. Sodium falls back to `salt × 400 mg`.
- Macros above 100 g per 100 g and energy above 950 kcal per 100 g are rejected as unit errors
  rather than imported.
- Dietary tags come from `categories_tags` keyword matching plus declared allergens (a legal
  statement about contents, hence trusted). An `en:vegan` analysis tag clears them outright, since
  that signal beats any category-name guess; `en:vegetarian` clears the flesh tags.
- UPC-A is a 12-digit code that Open Food Facts stores as EAN-13 with a leading zero, so a
  12-digit miss is retried once with the zero prepended.

`FoodSearchResult.hasInconsistentEnergy(tolerance:)` flags remote records whose macros and energy
disagree, at a deliberately loose 25% — far looser than the 12% the bundled database is held to,
because crowd-sourced label data legitimately drifts and flagging a quarter of Open Food Facts
would train the user to ignore the warning.

## Import into SwiftData

`FoodDatabaseImporter` is a `@ModelActor`, so it owns a private `ModelContext` on its own executor
and runs off the main thread by construction. Four guarantees:

1. **Idempotent.** Rows match on `catalogID`, so re-running updates rather than duplicates.
2. **Versioned.** The manifest's `version` is recorded in `UserDefaults` under
   `"foodDatabaseVersion"`. An unchanged version does no work at all — but the built-in row count
   is checked too, so a user who reset their data is not left with an empty database because the
   version still "matched".
3. **Never touches user data.** Only `source == .builtIn` rows are considered. Custom foods and
   recipes are invisible to it, and the user state living on a built-in row — `isFavorite`,
   `timesLogged`, `lastLoggedAt`, `costPer100` — is read but never written. Only the
   catalogue-owned fields are copied, and only when they actually changed.
4. **Survives an upgrade that adds, changes and removes foods.** Additions insert; changes update
   in place so existing references keep working; removals are pruned only when nothing points at
   them.

That last point deserves its own paragraph. Before pruning, the importer gathers every food id
referenced by `FoodLogEntry`, `SavedMealItem` and `RecipeIngredient` in three fetches rather than
three per candidate. A withdrawn food that is referenced, favourited or has ever been logged is
**adopted** — converted to `source = .custom` with its `catalogID` cleared — rather than deleted.
The user keeps the food and every reference to it, the importer will never touch it again (that
is exactly the guarantee custom foods have), and a later database reintroducing the same slug
inserts a fresh built-in row instead of fighting over this one. Only genuinely unused withdrawn
foods are deleted.

Writes are saved every 200 rows so a first-run import never holds the whole change set in memory,
and progress is reported at most every 25 records so a fast import does not flood the main actor
with updates nobody can perceive. `now` is a parameter rather than a call to `Date()`, so the same
input produces the same `updatedAt`.

`resetBuiltInFoods()` deletes every built-in row and forgets the version, backing the settings
screen's rebuild action — which exists because a store that has gone strange is otherwise
unrecoverable without deleting the app.

## Barcode scanning

`BarcodeScannerService` wraps an `AVCaptureSession` with an `AVCaptureMetadataOutput`. It imports
`AVFoundation` and `Foundation` and nothing else — the view layer wraps its `previewLayer` in its
own representable, which is what lets the scanner be exercised without a view hierarchy.

- **Symbologies:** EAN-8, EAN-13, UPC-E and Code 128. UPC-A is absent on purpose — AVFoundation
  reports it as an EAN-13 with a leading zero, which is also how Open Food Facts stores it.
- **Permission** is a five-state answer, not a boolean: `ready`, `notDetermined`, `denied`,
  `restricted`, `noCamera`. The UI needs the distinction — the first warrants a prompt, the second
  a link to Settings, the last a quiet fall-back to typing the number.
- **The simulator has no camera.** `availability` reports `.noCamera` and `start()` throws
  `BarcodeScannerError.unavailable(.noCamera)` rather than trapping inside AVFoundation.
- **Threading.** `startRunning()` blocks for a noticeable fraction of a second, so configuration
  and start/stop are serialised onto a private queue that `start()` simply awaits. Metadata
  callbacks land on a second queue. Shared state is guarded by a lock and the type is
  `@unchecked Sendable`; an actor would force every camera callback through a suspension point.
- **Debouncing.** The metadata output fires several times a second while a packet sits in frame.
  The same value is suppressed for **2 s** — long enough that a held packet does not refire,
  short enough that deliberately rescanning to add a second portion is not a wait — and any
  emission at all is suppressed for **0.3 s**, so a shelf of packets cannot produce a burst. One
  code is emitted per callback.
- **Validation.** Only plausible GTINs are published: digits only, length 8, 12, 13 or 14. Code
  128 carries arbitrary text, so it is accepted only when it is in fact all digits of a GTIN
  length. A malformed read would otherwise become a wasted network round trip.
- Codes arrive on a single-consumer `AsyncStream` that survives stop/start cycles; `invalidate()`
  closes it. `setScanRegion(_:)` narrows detection to a band of the preview, which both speeds
  detection up and stops the scanner reading a neighbouring packet from the edge of the frame.
