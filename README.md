# Kite Tracker

Garmin Connect IQ watch app for the **Instinct Solar 2** that records
kite jumps from the on-wrist accelerometer, barometer, and GPS.

## What it does

- Press **START** on the watchface, launch **Kite Tracker**, press
  **START** again to begin a session.
- The app detects jumps automatically from the sensor stream:
  **accelerometer** (G-threshold takeoff, freefall confirmation,
  G-threshold landing), corroborated by **pressure** returning to
  baseline OR **GPS speed** dropping below 1.5 m/s.
- After each landing, a 2x2 grid shows the barometric height (BH),
  the accelerometer height (AH), the airtime (T), and the jump
  length (L).
- Press **START** to end the session. The FIT activity syncs to
  Garmin Connect and each jump appears as a lap with four custom
  fields: jump height (baro), jump height (accel), jump length,
  airtime.

## Sensors

| Sensor | Source | Rate |
|--------|--------|------|
| Accelerometer | `Sensor.getInfo().accel` | polled at 25 Hz (every 40 ms) |
| Barometric pressure | `Activity.getActivityInfo().rawAmbientPressure` | polled at 1 Hz |
| GPS position + speed | `Position.enableLocationEvents(LOCATION_CONTINUOUS)` | ~1 Hz |

Note: `Sensor.getInfo().pressure` is MSL-calibrated and was rejected.
The raw ambient pressure from the activity session is what we want
because it changes with altitude (~12 Pa / metre).

## Height calculations

For every detected jump we compute three independent estimates and
store them all in the FIT file so we can compare them later.

- **BH (barometric)** — ICAO formula on `_minPressure` (lowest Pa
  during flight) vs the takeoff baseline:
  `h = 44330 * (1 - (P / P0)^0.190263)` metres. Most accurate
  on a stationary wrist, less noisy at 1 Hz.
- **AH (accelerometer)** — split airtime into ascent and descent
  using `_peakTs` (timestamp of the pressure minimum = peak altitude).
  Each phase is half a free-fall:
  `h_ascent = g · t_ascent² / 2`, `h_descent = g · t_descent² / 2`,
  `AH = (h_ascent + h_descent) / 2`. Velocity-independent (works even
  when the rider jumps with non-zero initial velocity).
- **L (length)** — Haversine distance between takeoff and landing
  positions. Optional reference, mostly there for the screen and
  for the FIT file.
- **T (airtime)** — landing timestamp minus takeoff timestamp.

Jumps where BH <= 1 m **and** AH <= 1 m are filtered out (real
jumps are taller; sub-1 m readings are usually false positives like
button presses or wrist flicks).

## Jump-detection thresholds

| Constant | Value | Source |
|----------|-------|--------|
| `TAKEOFF_G` | 1.25 G | lower than typical — slow kite launches don't spike above 2 G |
| `LANDING_G` | 1.15 G | close to 1 G (freefall) but permissive |
| `TAKEOFF_SAMPLES` | 3 | sustained spike, ~120 ms at 25 Hz |
| `LANDING_SAMPLES` | 3 | sustained low-G, ~120 ms |
| `FREEFALL_G` | 1.05 G | mid-flight low-G confirmation |
| `FREEFALL_SAMPLES` | 1 | a single sample is enough — kite jumps rarely have sustained freefall on the wrist |
| `COAST_MS` | 1500 ms | debounce between consecutive jumps |

## Quick build

```bash
monkeyc -o build/app.prg -d instinct2 -f monkey.jungle
```

See [`docs/SIDELOAD.md`](docs/SIDELOAD.md) for installing on the watch
and [`docs/TESTING.md`](docs/TESTING.md) for running the simulator
and unit tests.

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
  SessionManager.mc       # ActivityRecording + FitContributor fields, FIT export
  JumpDetector.mc         # state machine: ARMED -> AIRBORNE -> LANDING -> COASTING
  SensorAggregator.mc     # ring buffers for accel / pressure / GPS samples
  StartView.mc            # "Press START to begin"
  SessionView.mc          # "Recording... Jumps: N"
  DoneView.mc             # "Session saved"
  SummaryView.mc          # 2x2 grid AH / BH / T / L after each jump
  AppInputDelegate.mc     # START / ENTER toggle
  Logger.mc               # [KITE] prefix wrapper around System.println
  test/
    SensorAggregatorTests.mc
    JumpDetectorTests.mc
docs/
  ENVIRONMENT.md          # macOS dev setup: Java, SDK, signing key
  SIDELOAD.md             # side-load to a real Instinct Solar 2
  TESTING.md              # simulator + unit-test workflow
```

## Notes

- **Custom FIT lap fields require a Connect IQ Store install.** The
  beta workflow (see `docs/SIDELOAD.md`) is the only way to make the
  custom columns visible in Garmin Connect mobile and web. A
  side-loaded `.prg` writes valid data to the FIT file (download
  with FITCSVTool to inspect it) but Connect won't render the
  columns because the rendering metadata lives in the app-store
  JSON, not in the `.prg`.
- **First-detected peaks may underestimate barometric height.** The
  pressure sensor is polled at 1 Hz. For a fast jump (apex in less
  than a second), we may sample the pressure only before and after
  the peak and lose ~12 Pa / m of accuracy. The accelerometer
  height is a useful cross-check in that case.
