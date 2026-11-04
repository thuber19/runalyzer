# Runalyzer TODO

> This file tracks ongoing and upcoming work across conversation sessions.
> Update it as tasks are started, completed, or added.

## Backlog

- [ ] Health habit tracker — remaining items
  - WidgetKit integration (iOS lock screen / home screen widget)

- [ ] Dashboard hierarchy — remaining phases
  - ~~Blood work category (once blood tracking is implemented)~~ ✅

- [ ] Blood work / lab results — remaining items
  - Correlate with recovery/training load (e.g. low ferritin → poor recovery)

- [ ] IMUSensorDriver hardening
  - Add CRC/checksum validation on downloaded IMU data (corrupt BLE packets produce silently wrong data)
  - Document endianness assumptions for firmware protocol (currently uses host-endian without explicit conversion)
  - Add `didFailToConnect` delegate handler in DeviceCoordinator (peripheral leaks after failed connect)
  - Replace `onPacket`/`onDownloadComplete` closures with Combine publishers (retain-cycle traps)
  - Remove dead code: `wasRecordingKey` UserDefaults writes (never read back)
  - Replace `print()` debug logging with `AppLogger`

- [ ] Multi-device sync (change log + local server)
  - Add `sync_log` table to track all DB mutations
  - Build local sync server (Vapor or Python)
  - QR code for encryption key sharing between devices
  - iPad companion app

- [ ] Multi-session flash storage (firmware)
  - IMU firmware currently stores one session at a time in flash
  - Support multiple sessions stored simultaneously before sync

- [ ] Nutrition / calorie tracking
  - New `.nutrition` measurement type with data points for calories, protein, carbs, fat
  - Barcode scanning (VisionKit/AVFoundation) → lookup via Open Food Facts API (free, no key)
  - Manual quick-entry for meals (just calories + macros)
  - Fallback manual entry when barcode not found in database
  - HomeTab tile with daily calorie/macro summary

## Completed

- [x] watchOS companion app — sauna / wellness session tracker
  - Phase 1: track sessions with multiple round types (Finnish, Bio/Mild, Steam, Cold Plunge, Whirlpool, Rest), live timer, Digital Crown support, heart rate monitoring
  - Phase 2: WatchConnectivity sync to iOS via `WellnessSyncProvider`, saves as `.wellnessSession` measurements
  - Phase 3: full iOS analytics — timeline bars, HR charts, per-round stats, wellness tile on HomeTab

- [x] HealthKit background delivery
  - `HKObserverQuery` for 6 key types: workouts, sleep (immediate), HRV, RHR, steps, active energy (hourly)
  - `enableBackgroundDelivery` registered in `HealthKitManager`, wired via `AppWiring.setup()`
  - `processing` background mode + `healthkit.background-delivery` entitlement added
  - Triggers existing `refreshMetricsAndRecovery()` pipeline — no new providers needed

- [x] Redesign WorkoutDetailView following Apple HIG
  - Hero header with centered activity icon, name, date, prominent duration
  - 3-column metrics grid with SF Symbols (distance, HR, calories, pace, cadence)
  - `ScrubbingLineChart` for HR, pace, and cadence (drag-to-scrub, consistent styling)
  - Clean splits table with per-minute breakdown
  - Inline navigation title display mode

- [x] Blood work / lab results tracking — core
  - New `.labResults` measurement type with 16 biomarker DataTypes (glucose, HbA1C, LDL, HDL, triglycerides, total cholesterol, ferritin, vitamin D, iron, hemoglobin, creatinine, TSH, cortisol, testosterone, B12, CRP)
  - `LabResultsEntrySheet` manual entry UI (date + optional lab name + grouped biomarker fields)
  - `CategoryDashboardView.bloodWork()` with 12 weighted metrics, `queryMeasurementType` support
  - HomeTab "LABS" tile with latest glucose/lipid summary + toolbar entry button
  - Lab results summary in `MeasurementDetailView`
  - "Labs" filter in `DataTab` with swipe-to-delete
  - Trend views via existing `MetricTrendView` (reused, no changes needed)

- [x] Dashboard hierarchy — Phase 1, 2 & 3
  - `DashboardTile` + `CustomTile` — reusable tile components (Views/Components/)
  - `ScrubbingLineChart` — interactive line chart with drag-to-scrub, replaces MetricTrendView inline chart
  - `IntervalTimeline` — reusable stacked interval chart, replaces SleepNightDetailView inline hypnogram
  - `Sparkline` — minimal sparkline for dashboard tiles
  - `CategoryDashboardView` — generic category dashboard with metric tiles, time range picker
  - Heart category: combined RHR + HRV tile → Heart dashboard (RHR, HRV, SpO2, VO2 Max)
  - `HealthScore` algorithm: z-score normalization against personal 30-day baseline, weighted composite
  - Heart tile shows composite score (0–100) with label, Heart dashboard shows score ring + per-metric % change
  - `MetricDefinition` includes direction (higherIsBetter/lowerIsBetter) and weight for scoring
  - HomeTab refactored to use reusable components

- [x] Health habit tracker — core
  - Habit model with 4 schedule types (daily, everyNDays, xPerWeek, specificDays)
  - HabitStore with reactive GRDB ValueObservation, CRUD, toggle/auto-fulfill
  - HabitProvider auto-fulfillment engine (matches workouts to linked habits)
  - HabitStreak algorithm (current/longest streak, weekly/monthly compliance)
  - HabitsView with today's checklist, streak display, compliance bars, add habit sheet
  - HomeTab dashboard tile showing today's completion progress
  - Supplement tracking: category field + quick-add presets (creatine, vitamin D, omega-3, etc.)
  - HabitDetailView: calendar heat-map of completions, streak/compliance stats
  - `source` field on `habit_log` (manual vs auto), v4 DB migration with backfill

- [x] Code audit + production hardening
  - N+1 query fix (MeasurementStore ValueObservation, MetricIndex)
  - Thread safety (RunMetrics @MainActor dispatch, store error logging)
  - Error handling (AppLogger everywhere, force unwrap removal, HealthKit guard lets)
  - ShareSheet rename to ActivityShareSheet (SDK collision)
  - DateFormatter caching (DataTab, WorkoutDetailView, SleepTrendView)
  - Dead code removal (stripHeartRateSamplesFromMetrics)

- [x] SQLCipher database encryption
  - Switched from groue/GRDB.swift to sqlcipher/GRDB.swift (encrypted GRDB fork)
  - 256-bit encryption key generated and stored in Keychain
  - Database encrypted at rest with SQLCipher
  - Plaintext→encrypted migration for existing databases
  - Export/import updated to use sqlcipher_export

- [x] UserProfile moved to database
  - New `user_profile` table (v2 migration)
  - UserProfileProvider: owns persistence + HealthKit auto-fill (sex, DOB→age, height)
  - Removed UserProfile from Keychain/UserDefaults

- [x] Architecture cleanup
  - Removed SessionStore + SessionListView (legacy JSON-file storage)
  - Removed EnrichmentProvider + SessionEnrichment (dead code under new architecture)
  - Removed JSON→SQLite migration code (no backwards compatibility needed)
  - Scale pipeline refactored: QNScaleDriver emits raw ScaleReading → ScaleMeasurementProvider fetches profile → BodyComposition algorithm → saves
  - BodyComposition moved to Algorithms/ (pure computation)
  - UserProfile extracted to Storage/UserProfile.swift (plain data model)
  - Drivers are now BLE-only (no profile lookups, no algorithms, no DB access)

- [x] GRDB Migration — ALL PHASES
- [x] Source Preferences settings page
- [x] Time by Activity chart in WorkoutAnalyticsView
- [x] Distance chart filtered to distance-relevant activities only
- [x] Legacy source string migration (device UUIDs normalized)
- [x] HR sample metric import removed (memory optimization)
