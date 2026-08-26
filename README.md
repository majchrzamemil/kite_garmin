# Kite Tracker

Garmin Connect IQ watch app for the **Instinct Solar 2** that records
kite jumps from the on-wrist accelerometer, barometer, and GPS.
**Validated end-to-end on a real Instinct Solar 2.**

## What it does

- Press **START** on the watchface, launch **Kite Tracker**, press
  **START** again to begin a session.
- The app detects jumps automatically from the sensor stream using a
  **hybrid filter**: an accelerometer takeoff spike (≥ 1.10 G total-G
  for ~120 ms) starts an airborne window, and a barometric pressure
  drop (≥ 20 Pa from the pre-jump baseline within the first second)
  confirms it was a real altitude change. Sub-1-second events and
  candidates with no altitude change are discarded.
- Landing is detected by **three independent paths** in priority order:
  barometric pressure returns to baseline **and** the descent rate
  flattens (preferred), GPS speed drops below 1.5 m/s for 500 ms
  (backup), or a low-G impact spike + freefall confirmation
  (legacy, requires pressure or GPS corroboration). A 20 s
  `MAX_FLIGHT_MS` watchdog force-lands the jump if nothing else
  closes it.
- After each landing, `SessionManager.addJumpLap` checks the
  barometric height against a 1.5 m gate and the airtime against a
  1 s gate; jumps that pass are written as a FIT lap and trigger a
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

### Algorithm — hybrid jump detection

A jump is recognised in three stages.

1. **Takeoff (`STATE_ARMED` → `STATE_AIRBORNE`).** Three consecutive
   accelerometer samples whose total-G magnitude meets or exceeds
   `TAKEOFF_G = 1.10` (~120 ms at 25 Hz effective rate). Lowered
   from the original 1.25 after field tests showed soft kite
   launches never spike above ~1.2 G.
2. **Pre-landing gate (`_maybeLand`, must pass before any landing
   path fires).**
   - Airborne for at least `MIN_FLIGHT_MS = 1000` ms. Sub-second
     events (wind gusts, bar yanks, wrist impacts) are discarded.
   - Pressure has dropped by at least `TAKEOFF_PRESSURE_DROP_PA = 20`
     Pa from the pre-jump baseline (~1.7 m of climb). Sustained
     low-G windows without altitude change are discarded by
     `_discardJump`.
   - The lowest Pa observed during flight (`_minPressure`) is updated
     from the latest pressure sample, but a single-sample drop larger
     than `SPLASH_OUTLIER_PA = 100` Pa is rejected as a water splash
     or sensor glitch. Real climbs are captured; isolated outliers
     cannot permanently set the peak for the whole jump.
3. **Landing.** Three paths in priority order:
   - **Pressure (preferred).** `|P_current - P_baseline| <= PRESSURE_RETURN_PA` (20 Pa)
     AND `|descentRate| <= DESCENT_FLAT_PA_S` (5 Pa/s) — descent
     rate is computed by `_descentRatePaS` over a 4-sample pressure
     ring buffer.
   - **GPS speed (backup).** Ground speed below `GPS_SPEED_LOW_MPS = 1.5` m/s
     for at least `GPS_LOW_FOR_LAND_MS = 500` ms.
   - **Low-G impact (legacy + corroboration).** Three consecutive
     samples below `LANDING_G = 1.15`, freefall confirmed mid-flight
     (`_freefallConfirmed`), AND corroboration from pressure or GPS.
4. **Watchdog (`tick`).** If the detector is still `AIRBORNE` after
   `MAX_FLIGHT_MS = 20000` ms, `_forceLanding("maxFlightMs")` fires.
   The 20 Pa pressure-drop gate applies here too — a 20 s hang
   without altitude change is discarded.

### Record gate (`SessionManager.addJumpLap`)

All three must hold for a landed jump to be written as a FIT lap:

- `baroH > 1.5` m.
- `airtimeS > 1.0` s.
- Sanity caps: `baroH <= 20.0` m **and** `lengthM <= 100.0` m. A jump
  whose barometric height exceeds 20 m or whose takeoff-to-landing
  distance exceeds 100 m is logged and skipped — neither value is a
  realistic kiteboarding jump on a wrist-mounted sensor, and the
  discard is the second line of defence against splash/weather-driven
  pressure outliers that slip past the outlier rejection on `_minPressure`.

Jumps failing any of these are logged but never reach the FIT file
and never trigger `SummaryView`.

### Height

Barometer-only. `h = 44330 * (1 - (P_min / P_0)^0.190263)` on the
lowest Pa observed during flight vs the takeoff baseline (ICAO
formula). The accelerometer-derived ascent/descent height that the
project originally produced is no longer used — wrist motion during
riding made the half-freefall estimate too noisy on real data.

### Jump-detection constants

| Constant | Value | Notes |
|----------|-------|-------|
| `TAKEOFF_G` | **1.10** | Soft over-correction; sub-1 m jumps are filtered by `SessionManager`. |
| `LANDING_G` | 1.15 | Close to 1 G (freefall) but permissive. |
| `TAKEOFF_SAMPLES` | 3 | Sustained spike, ~120 ms at 25 Hz. |
| `LANDING_SAMPLES` | 3 | Sustained low-G, ~120 ms. |
| `FREEFALL_G` | 1.05 | Mid-flight low-G confirmation. |
| `FREEFALL_SAMPLES` | 1 | A single sample is enough. |
| `MIN_FLIGHT_MS` | **1000** | No landing path may fire before 1 s. |
| `TAKEOFF_PRESSURE_DROP_PA` | **20** | Required Pa drop after 1 s or the jump is discarded. |
| `PRESSURE_RETURN_PA` | 20 | Pressure-return window for the pressure landing path. |
| `DESCENT_FLAT_PA_S` | 5 | Maximum descent rate (Pa/s) for the pressure landing path. |
| `GPS_SPEED_LOW_MPS` | 1.5 | GPS landing speed threshold. |
| `GPS_LOW_FOR_LAND_MS` | 500 | GPS-low dwell required before the GPS path fires. |
| `MAX_FLIGHT_MS` | **20000** | AIRBORNE watchdog (lowered from 30000 — kite jumps are typically under 10 s, 20 s is a tight safety net that also limits the airborne window during which a bad pressure sample can pollute `_minPressure`). |
| `SPLASH_OUTLIER_PA` | **100** | Single-sample pressure drop larger than this is rejected as a splash/sensor glitch (~8.3 m at sea level). |
| `COAST_MS` | 1500 | Debounce between consecutive jumps. |

The final 1.5 m / 1 s / 20 m / 100 m record gate in
`SessionManager.addJumpLap` is the third line of defence (after the
two detector-side gates: `MIN_FLIGHT_MS` + `TAKEOFF_PRESSURE_DROP_PA`,
and the outlier-rejected `_minPressure` peak detection).

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
the detection lines (`JUMP AIRBORNE`, `detector: landing path=...`,
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
