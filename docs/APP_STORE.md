# App Store submission sheet

Everything App Store Connect asks for, ready to paste. English is the primary language; Spanish is
provided as a full localisation. The other eight languages the app ships in can fall back to English
metadata, or be added later — the screenshots already exist for all ten.

---

## 1. Build

| Field | Value |
|---|---|
| Bundle ID | `com.alejandronewport.forge` (widget: `com.alejandronewport.forge.widgets`) |
| App Group | `group.com.alejandronewport.forge` |
| Team | `SM3MGV3PY8` |
| Version / build | `1.0.0` (`1`) — `MARKETING_VERSION` / `CURRENT_PROJECT_VERSION` in `project.yml` |
| Archive | Xcode → Window → Organizer → *Forge 1.0.0 (1)* |
| Devices | iPhone and iPad, iOS 18.0 or later |
| Encryption | `ITSAppUsesNonExemptEncryption = false` — no export-compliance questions |

To upload: Organizer → select the archive → **Distribute App** → **App Store Connect** → **Upload**.
For the next build, bump `CURRENT_PROJECT_VERSION`, run `Tools/regen.sh`, then Product → Archive.

## 2. App information

| Field | Value |
|---|---|
| Name (EN) | Forge: Workout & Nutrition |
| Name (ES) | Forge: Entreno y Nutrición |
| Subtitle (EN) | Adaptive gym plans and macros |
| Subtitle (ES) | Rutinas y macros adaptativos |
| Primary category | Health & Fitness |
| Secondary category | Food & Drink |
| SKU | `forge-ios-1` (any unique string; never shown) |
| Content rights | Contains third-party content, with the rights to use it: the exercise dataset (MIT), USDA FoodData Central (public domain) and Open Food Facts (ODbL), all credited in Settings → Legal |
| Copyright | 2026 Alejandro Newport Diaz |

The name must be unique on the App Store. If App Store Connect rejects one, the home-screen name stays
"Forge" whatever the listing is called.

## 3. Version information

### Promotional text

**EN** — Your plan adapts after every session: load, reps and calories follow what you actually did,
and every change tells you why. No account, no ads, works offline.

**ES** — Tu plan se adapta tras cada sesión: carga, repeticiones y calorías siguen lo que de verdad
hiciste, y cada cambio te dice por qué. Sin cuenta, sin anuncios, sin conexión.

### Keywords

**EN** — `training,planner,strength,progressive overload,hypertrophy,calorie,food log,barcode,deload,tdee`

**ES** — `gimnasio,pesas,fuerza,hipertrofia,sobrecarga progresiva,calorías,dieta,código de barras,entrenador`

Words already in the name and subtitle are left out: the App Store indexes those anyway.

### Description (EN)

```
Forge plans your training and nutrition, then adjusts both to what you actually do.

A PLAN BUILT FOR YOU
Tell Forge your goal, experience, schedule and equipment. It picks a split, sets weekly volume for every muscle group and fills each session with exercises chosen for you.

500 EXERCISES, EACH ANIMATED
Every exercise comes with an original 3D animation of the same athlete, so you always see the movement clearly, plus step-by-step instructions in ten languages.

PROGRESSION THAT EXPLAINS ITSELF
After each session Forge decides, exercise by exercise, whether to add weight, add reps, hold or back off — and tells you why: "Increased your bench press from 60 to 62.5 kg because you completed 3×12 twice with reps in reserve." When the pattern says you need a lighter week, it suggests a deload. It never imposes one.

SWAP ANY EXERCISE
Machine taken? Only dumbbells? Want something easier? Ask for an alternative and Forge ranks the fairest swaps by muscle, movement and equipment.

NUTRITION THAT FOLLOWS YOUR WEIGHT
Calorie and macro targets come from your profile and goal. A weekly weight trend proposes adjustments, which you accept or decline. Log food from a built-in database that works offline, scan a barcode, or add your own foods, meals and recipes.

YOU STAY IN CHARGE
Override any recommendation, lock any exercise, or build a program from scratch. Track progress with charts, personal records and achievements, and keep your next workout and today's macros on a widget.

PRIVATE BY DESIGN
No account, no ads, no tracking. Your data stays on your device. Apple Health is optional, and you can export or back up everything at any time.

Forge gives fitness and nutrition estimates for healthy adults. It is not medical advice.
```

### Description (ES)

```
Forge planifica tu entrenamiento y tu nutrición, y ajusta ambos a lo que de verdad haces.

UN PLAN HECHO PARA TI
Cuéntale a Forge tu objetivo, tu experiencia, tu horario y tu material. Elige una división, fija el volumen semanal de cada grupo muscular y llena cada sesión con ejercicios escogidos para ti.

500 EJERCICIOS, TODOS ANIMADOS
Cada ejercicio tiene una animación 3D original del mismo atleta, para que siempre veas el movimiento con claridad, e instrucciones paso a paso en diez idiomas.

UNA PROGRESIÓN QUE SE EXPLICA
Tras cada sesión, Forge decide ejercicio a ejercicio si subir peso, sumar repeticiones, mantener o aflojar, y te dice por qué: «He subido tu press de banca de 60 a 62,5 kg porque completaste 3×12 dos veces con repeticiones en reserva». Cuando ve que necesitas una semana más ligera, te propone una descarga. Nunca te la impone.

CAMBIA CUALQUIER EJERCICIO
¿La máquina está ocupada? ¿Solo tienes mancuernas? ¿Quieres algo más fácil? Pide una alternativa y Forge ordena los cambios más justos por músculo, movimiento y material.

UNA NUTRICIÓN QUE SIGUE A TU PESO
Los objetivos de calorías y macros salen de tu perfil y tu meta. La tendencia semanal de tu peso propone ajustes que tú aceptas o rechazas. Registra comida desde una base de datos integrada que funciona sin conexión, escanea un código de barras o añade tus propios alimentos, comidas y recetas.

TÚ TIENES EL CONTROL
Cambia cualquier recomendación, bloquea cualquier ejercicio o crea un programa desde cero. Sigue tu progreso con gráficas, récords personales y logros, y ten tu próximo entreno y los macros del día en un widget.

PRIVADA DE SERIE
Sin cuenta, sin anuncios, sin rastreo. Tus datos se quedan en tu dispositivo. Salud de Apple es opcional, y puedes exportar o hacer copia de todo cuando quieras.

Forge ofrece estimaciones de forma física y nutrición para adultos sanos. No es consejo médico.
```

### URLs

| Field | Value |
|---|---|
| Support URL | **Required — still to publish.** Any page with a way to contact you. |
| Privacy Policy URL | **Required — still to publish.** Host `docs/PRIVACY.md` (e.g. GitHub Pages, or the file on GitHub if the repository is public). |
| Marketing URL | Optional |

### Screenshots

Upload from `Screenshots/`, generated by `Tools/screenshots.sh --all-languages`:

| App Store Connect slot | Folder | Size |
|---|---|---|
| iPhone 6.9" Display | `Screenshots/iphone-6.9/<language>/` | 1320 × 2868 |
| iPad 13" Display | `Screenshots/ipad-13/<language>/` | 2064 × 2752 |

Eight per set, in order: Home, today's workout, active session, exercise library, exercise detail,
food log, Progress, Settings. Languages: `en es it tr ru zh-Hans hi pl ko fr`.

## 4. App Privacy

Answer **Data Not Collected**.

Nothing leaves the device except, when the user searches for a packaged product or scans a barcode,
the search term or barcode itself, sent to Open Food Facts to answer that request. It carries no
identifier, is not linked to the user and is not kept by the developer, which is the case Apple
excludes from "collection". `GymApp/App/PrivacyInfo.xcprivacy` declares no tracking, no tracking
domains and no collected data types. Details: `docs/PRIVACY.md`.

## 5. Age rating

Answer **None / No** to every content question (violence, sexual content, profanity, gambling,
horror, alcohol or drugs, user-generated content, unrestricted web access, messaging). For medical
or treatment information, answer **No**: the app gives general fitness and nutrition estimates, not
diagnosis or treatment. Expected rating: **4+**.

## 6. App Review information

| Field | Value |
|---|---|
| Sign-in required | No |
| Contact | Your name, phone and email |

**Notes for the reviewer:**

```
Forge needs no account and works fully offline. On first launch a short questionnaire builds a training program; every screen is reachable afterwards from the tab bar.

- Apple Health is optional and off until the user enables it in Settings → Health. The app reads body mass, height, workouts, active energy, steps and sleep, and writes only completed workouts and body-mass entries.
- The camera is used only to scan food barcodes (Nutrition → add food → scan). Barcode and search lookups go to Open Food Facts; nothing else contacts a server.
- Notifications are local and off by default.
- Calorie, macro and training figures are estimates for healthy adults, not medical advice; the app says so next to its energy targets and in Settings → Legal.
- Exercise illustrations are original 3D renders made for this app.
```

## 7. Before pressing Submit

- [ ] Create the app record in App Store Connect with bundle ID `com.alejandronewport.forge`.
- [ ] Publish the privacy policy and a support page, and paste both URLs.
- [ ] Upload the archive from the Organizer and wait for processing.
- [ ] On a real device: grant and then deny Health, scan a real barcode, and let a rest timer finish
      with the app in the background — the Simulator cannot exercise these.
- [ ] Attach the screenshots, fill sections 2–6, select the build, submit.
