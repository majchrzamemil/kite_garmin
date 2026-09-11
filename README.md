# Kite Tracker

Garmin Connect IQ watch app for the **Instinct Solar 2** that records
kite jumps from the on-wrist accelerometer, barometer, and GPS.
**Validated end-to-end on a real Instinct Solar 2.**

## What it does

- Press **START** on the watchface, launch **Kite Tracker**, press
  **START** again to begin a session.
- The app detects jumps with a **landing-first** algorithm: the
  trigger is the **landing impact** (total-G ≥ 1.8 G for ~80 ms — the
  single biggest, rarest wrist signal in kiteboarding), and the
  jump is validated by walking **backwards** through the
  pre-impact window: the flight must be a *quiet* accelerometer
  window (riding chop stops when you leave the water) of 0.8–8 s
  containing at least one reduced-G sample (< 0.9 G), and the
  median-of-3 smoothed barometer must show a **dip-and-return**
  shape — ≥ 18 Pa below the pre-takeoff baseline during flight and
  back within 30 Pa of it after landing. The return check is what
  rejects tack ram-air drift; the median kills single-sample splash
  spikes.
- After each recorded jump, `SessionManager.addJumpLap` checks the
  barometric height against a 1.2 m gate and the airtime against a
  0.75 s gate; jumps that pass are written as a FIT lap and trigger a
  short `SummaryView` popup showing a large centred height with the
  proper `m` suffix. A sanity discard rejects any landed jump whose
  barometric height exceeds 20 m or whose takeoff-to-landing distance
  exceeds 100 m — neither value is a realistic kiteboarding jump on a
  wrist-mounted sensor, and the discard prevents splash/weather-driven
  pressure outliers from polluting the FIT file.
- Press **START** to end the session. The `SessionReviewView` lists
  every recorded jump one per screen; UP/DOWN scrolls the list,
  BACK exits. The FIT activity syncs to Garmin Connect and each jump
  appears as a lap with the custom lap fields declared in
  `resources/fitcontributions/fitcontributions.xml`.

## How it works

### Sensors

| Sensor | Source | Rate |
|--------|--------|------|
| Accelerometer | `Sensor.getInfo().accel` | polled via `Timer` at 40 Hz |
| Barometric pressure | `Activity.getActivityInfo().rawAmbientPressure` | polled via `Timer` at 1 Hz |
| GPS position + speed | `Position.enableLocationEvents(LOCATION_CONTINUOUS)` | ~1 Hz |

Note: `Sensor.getInfo().pressure` is MSL-calibrated and was rejected.
The raw ambient pressure from the activity session is what we want
because it changes with altitude (~12 Pa / metre).

`Sensor.registerSensorDataListener` (API 2.3.0) crashes on Connect IQ
6.0.2 devices including the Instinct Solar 2, so the accelerometer
runs on the legacy `Sensor.getInfo()` poll loop instead.

### Algorithm — landing-first jump detection

A jump is recognised by its **landing**, then validated by looking
backwards at the window before the impact. This inverts the original
takeoff-first design, which produced a flood of fake jumps on real
water: a 1.10 G takeoff threshold sits inside riding-chop noise, and
a 20 Pa barometric "climb" gate is satisfied ~38% of all seconds by
ram-air pressure changes through tacks and water film on the
pressure port. The landing impact is the single biggest, rarest,
cleanest wrist signal in kiteboarding, so it is the trigger.

1. **Landing impact trigger (`STATE_ARMED`).** Total-G ≥
   `LANDING_SPIKE_G = 1.8` for `LANDING_SPIKE_SAMPLES = 2` consecutive
   samples (~80 ms). A single chop slap does not fire on its own.
2. **Backward airborne-window scan (`_analyzeLanding`).** Walk back
   through the pre-impact accelerometer history: an airborne wrist is
   *quiet* (chop noise stops when you leave the water). A sample
   above `AIRBORNE_G_HIGH = 1.5` is an excursion (chop hit, edge
   load, kite yank, pop). The window ends at "riding": an excursion
   run longer than `EXCURSION_RUN_MAX = 5` samples, or more than
   `MAX_WINDOW_EXCURSIONS = 8` cumulative excursion samples (chop
   occurs every 300–800 ms while riding). The takeoff is anchored at
   the first excursion inside the window (the pop) when present,
   else at the window start.
3. **Flight gates.** Airtime within `MIN_FLIGHT_MS = 800` and
   `MAX_FLIGHT_MS = 8000` ms, and at least one sample below
   `FREEFALL_SOFT_G = 0.90` G inside the flight (weightlessness
   evidence — the apex of even a small jump dips below 0.9 G for a
   few samples at 25 Hz). Candidates that fail any gate are discarded
   with a short (`DISCARD_COAST_MS = 300` ms) cooldown so a pop spike
   does not blind the detector to the real landing that follows.
4. **PENDING confirmation window.** A candidate is held for
   `PENDING_MS = 1500` ms after the landing so post-landing
   barometer samples arrive at the 1 Hz poll rate.
5. **Barometric dip-and-return gate (`_maybeCompletePending`).** On
   the median-of-3 smoothed pressure series: the baseline is the
   median of samples in `[takeoff − 4 s, takeoff − 0.5 s]`; the
   flight must dip ≥ `BARO_DIP_PA = 18` Pa below it; and the latest
   post-landing sample must be back within `BARO_RETURN_PA = 30` Pa
   of it. The return check is what rejects tack ram-air drift
   (pressure steps down through a turn and *stays* down). The
   median-of-3 smoothing kills single-sample splash spikes of any
   size — the old `SPLASH_OUTLIER_PA` constant is gone.
6. **No watchdog.** There is no persistent AIRBORNE state to get
   stuck: a candidate that fails any gate is discarded, never
   force-landed into the FIT file. The GPS-speed landing path is
   gone too — real kite jumps land at riding speed (5–8 m/s), so
   that path could only ever close fake events.

States: `IDLE` → `ARMED` → (landing spike) → `PENDING` → (baro
confirmation) → `COASTING` → `ARMED`.

### Record gate (`SessionManager.addJumpLap`)

All must hold for a validated jump to be written as a FIT lap:

- `baroH > 1.2` m.
- `airtimeS > 0.75` s.
- Sanity caps: `baroH <= 20.0` m **and** `lengthM <= 100.0` m. A jump
  whose barometric height exceeds 20 m or whose takeoff-to-landing
  distance exceeds 100 m is logged and skipped — neither value is a
  realistic kiteboarding jump on a wrist-mounted sensor.

Jumps failing any of these are logged but never reach the FIT file
and never trigger `SummaryView`.

### Height

Barometer-only. `h = 44330 * (1 - (P_min / P_0)^0.190263)` on the
lowest *median-of-3 smoothed* Pa observed during flight vs the
pre-takeoff baseline median (ICAO formula). The accelerometer-derived
ascent/descent height that the project originally produced is no
longer used — wrist motion during riding made the half-freefall
estimate too noisy on real data.

### Jump-detection constants

| Constant | Value | Notes |
|----------|-------|-------|
| `LANDING_SPIKE_G` | **1.8** | Landing impact trigger. |
| `LANDING_SPIKE_SAMPLES` | 2 | Sustained ~80 ms at 25 Hz; single chop slaps don't fire. |
| `AIRBORNE_G_HIGH` | 1.5 | Above this a sample is an excursion (chop / edge / yank / pop). |
| `EXCURSION_RUN_MAX` | 5 | An excursion run longer than this = riding; window stops. |
| `MAX_WINDOW_EXCURSIONS` | 8 | Cumulative excursions in the window; chop hits this within ~2 s. |
| `MIN_FLIGHT_MS` | **800** | Shorter quiet window = chop slap, not a jump. |
| `MAX_FLIGHT_MS` | **8000** | Backward scan cap (also the airtime ceiling). |
| `FREEFALL_SOFT_G` | **0.90** | ≥ 1 sample below this in flight = weightlessness evidence. |
| `BARO_DIP_PA` | **18** | Required smoothed dip below baseline during flight (~1.5 m). |
| `BARO_RETURN_PA` | **30** | Post-landing sample must return this close to baseline. |
| `BASELINE_BACK_MS` | 4000 | Baseline median window starts this far before takeoff. |
| `BASELINE_GAP_MS` | 500 | Baseline median window ends this far before takeoff. |
| `PENDING_MS` | 1500 | Post-landing wait for 1–2 fresh baro samples. |
| `PRESSURE_LOOKBACK` | 20 | Pressure samples pulled from the ring at confirmation. |
| `COAST_MS` | 1500 | Debounce after a recorded jump. |
| `DISCARD_COAST_MS` | 300 | Short cooldown after a discarded event (e.g. a pop spike). |
| `G_RING_CAPACITY` | 360 | Internal G-magnitude ring, ~9 s at the 40 Hz poll rate. |

The final 1.2 m / 0.75 s / 20 m / 100 m record gate in
`SessionManager.addJumpLap` is the last line of defence behind the
detector-side gates (landing impact, quiet window, reduced-G
sample, and the barometric dip-and-return shape).

## Building

```bash
cd /Users/em/Documents/repos/kite_garmin
./build.sh
```

`build.sh` invokes `monkeyc -y ~/.Garmin/connect_iq_dev_key.der
-o build/app.prg -d instinct2 -f monkey.jungle` and writes
`build/app.prg`. Equivalent one-liner:

```bash
monkeyc -o build/app.prg -d instinct2 -f monkey.jungle
```

Expected output: `BUILD SUCCESSFUL`. See
[`docs/SIDELOAD.md`](docs/SIDELOAD.md) for installing on the watch.

For the unit-test build add `--unit-test`:

```bash
monkeyc -y ~/.Garmin/connect_iq_dev_key.der \
         -o build/test.prg \
         -d instinct2 \
         -f monkey.jungle \
         --unit-test
```

See [`docs/TESTING.md`](docs/TESTING.md) for the simulator and unit
test workflow.

## Installing

The build artifact is `build/app.prg`. On the Instinct Solar 2 the
correct side-load path is `/Volumes/GARMIN/GARMIN/Apps/` (the
top-level `/Volumes/GARMIN/Apps/` folder is ignored by the watch).
The watch must be in **File Transfer / MTP** mode for macOS to
mount it as a drive; if it does not mount, use [OpenMTP](https://openmtp.ganeshrvel.com/).

Full step-by-step (including the OpenMTP fallback, the `APP.TXT`
log-pull workflow, and the case-sensitivity trap) lives in
[`docs/SIDELOAD.md`](docs/SIDELOAD.md).

## Log pulling

On the device, `System.println` from a side-loaded app is written to
a file in `GARMIN/Apps/LOGS/` with the **same base name** as the
`.prg`, in **uppercase** (the Instinct Solar 2's FAT filesystem is
case-sensitive):

```
/Volumes/GARMIN/GARMIN/Apps/LOGS/APP.TXT
```

The project pre-creates both `APP.TXT` and a lowercase `app.TXT`
fallback when side-loading; whichever the watch writes to is the
file to pull. Lines prefixed with `[KITE]` come from `Logger.mc`.
Verbose logs from `SessionReviewView` are intentionally stripped so
the detection lines (`JUMP CANDIDATE`, `detector: discard ...`,
`JUMP LANDED`, `SESSION_DUMP_*`) stay readable when scrolling
through a 20-jump session.

## Testing

Unit tests live in `source/test/`. Each `(:test)`-annotated function
is compiled only by the `--unit-test` build:

```bash
monkeyc -y ~/.Garmin/connect_iq_dev_key.der \
         -o build/test.prg \
         -d instinct2 \
         -f monkey.jungle \
         --unit-test
open -a ConnectIQ
monkeydo build/test.prg instinct2 -t
```

The full suite covers `SensorAggregator` ring-buffer behaviour and
the `JumpDetector` state machine, including the multi-jump regression
tests added after the real-watch crash on the second jump of a
session. See [`docs/TESTING.md`](docs/TESTING.md) for the simulator
caveats and the real-watch testing workflow.

> The Connect IQ simulator hangs on launch in this development
> environment; `--unit-test` builds succeed but `monkeydo -t` cannot
> be executed here. See `docs/TESTING.md` for the simulator caveats
> and known pre-existing test failures.

## Device support

| Field | Value |
|-------|-------|
| Target device | Garmin Instinct Solar 2 |
| Connect IQ product id | `instinct2` |
| Min API level | 3.0.0 |
| Manifest | `manifest.xml` (single product) |
| Build key | `~/.Garmin/connect_iq_dev_key.der` |

## Project layout

```
manifest.xml              # Connect IQ app manifest (sport, perms, fields)
monkey.jungle             # build descriptor
build.sh                  # wrapper that injects the signing key
resources/
  drawables/              # launcher_icon.svg + .png (kite silhouette)
  fitcontributions/       # fitcontributions.xml (FIT lap field definitions)
  strings/                # app name + labels
source/
  App.mc                  # entry point, sensor pipeline, session lifecycle
  AppInputDelegate.mc     # START / ENTER toggle
  SessionManager.mc       # ActivityRecording + FitContributor fields, FIT export
  JumpDetector.mc         # state machine: IDLE -> ARMED -> AIRBORNE -> LANDING -> COASTING
  SensorAggregator.mc     # ring buffers for accel / pressure / GPS samples
  StartView.mc            # "Press START to begin"
  SessionView.mc          # "Recording... Jumps: N"
  SummaryView.mc          # big centred height popup after each recorded jump
  SessionReviewView.mc    # end-of-session scrollable review (UP/DOWN)
  SessionReviewInputDelegate.mc
  DoneView.mc             # superseded by SessionReviewView (kept for now)
  Logger.mc               # [KITE] prefix wrapper around System.println
  test/
    SensorAggregatorTests.mc
    JumpDetectorTests.mc
docs/
  ENVIRONMENT.md          # macOS dev setup: Java, SDK, signing key
  SIDELOAD.md             # side-load to a real Instinct Solar 2
  TESTING.md              # simulator + unit-test workflow
```

## Screens

| View | When it appears | What it shows |
|------|-----------------|---------------|
| **StartView** | App launch | "Press START to begin" |
| **SessionView** | During recording | Recording status and jump count (`Jumps: N`) |
| **SummaryView** | Immediately after a recorded jump | Large centred height (e.g. `4.2m`) plus time and travel on the line below |
| **SessionReviewView** | After ending the session | Scrollable list of recorded jumps (UP/DOWN). Each screen shows height, length, and airtime |

Example SummaryView layout on the 176×176 Instinct Solar 2 screen:

```
+-----------------+
|                 |
|                 |
|      4.2m       |
|                 |
|   2.5s   5.1m   |
|                 |
+-----------------+
```

All text is centred and kept away from the top-right circular bezel.

Screenshot assets: `assets/screenshots/`

## Notes

- **Custom FIT lap fields require a Connect IQ Store install.** The
  beta workflow (see `docs/SIDELOAD.md` § Publishing to Connect IQ
  Store) is the only way to make the custom columns visible in
  Garmin Connect mobile and web. A side-loaded `.prg` writes valid
  data to the FIT file (download with FITCSVTool to inspect it) but
  Connect won't render the columns because the rendering metadata
  lives in the app-store JSON, not in the `.prg`.
- **First-detected peaks may underestimate barometric height.** The
  pressure sensor is polled at 1 Hz. For a fast jump (apex in less
  than a second), we may sample the pressure only before and after
  the peak and lose ~12 Pa / m of accuracy. The 1.5 m record gate
  catches most of these cases by rejecting jumps whose peak pressure
  delta does not produce a clear height above baseline.
