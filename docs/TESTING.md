# Kite Tracker — Simulator & Unit Testing

This guide covers how to build the Kite Tracker app, run the unit-test
suite, and exercise the app in the Connect IQ simulator without
needing a physical Instinct Solar 2 on your desk. For real-watch
installs see `docs/SIDELOAD.md`.

> Target device: **Garmin Instinct Solar 2** (`instinct2` product id in the SDK).  
> Host: **macOS** with the Connect IQ SDK installed (see `docs/ENVIRONMENT.md`).

---

## 1. Build the app `.prg`

A normal build compiles only the entrypoint (`App.mc`) and the
non-annotated source files. Test files in `source/test/` carry the
`(:test)` annotation and are excluded automatically.

```bash
cd /Users/em/Documents/repos/kite_garmin
rm -rf build
mkdir -p build
monkeyc -y ~/.Garmin/connect_iq_dev_key.der \
         -o build/app.prg \
         -d instinct2 \
         -f monkey.jungle
```

Expected output: `BUILD SUCCESSFUL` and a `build/app.prg` artifact.

You can also use the wrapper script `./build.sh`, which injects the
`-y` key path for you.

---

## 2. Build the unit-test executable

Re-running `monkeyc` with `--unit-test` enables compilation of every
`(:test)`-annotated function. The same `monkey.jungle` file is reused;
no separate jungle file is needed because Connect IQ looks for the
`(:test)` annotation inside the existing source path.

```bash
cd /Users/em/Documents/repos/kite_garmin
rm -rf build
mkdir -p build
monkeyc -y ~/.Garmin/connect_iq_dev_key.der \
         -o build/test.prg \
         -d instinct2 \
         -f monkey.jungle \
         --unit-test
```

Expected output: `BUILD SUCCESSFUL` and a `build/test.prg` artifact
that contains the compiled test functions alongside the production
code.

---

## 3. Run tests in the simulator

1. Launch the Connect IQ simulator (it must be running before
   `monkeydo` is invoked):

   ```bash
   open -a ConnectIQ
   ```

2. From another shell, run the tests on the `instinct2` virtual device:

   ```bash
   monkeydo build/test.prg instinct2 -t
   ```

   The `-t` flag tells `monkeydo` to run the unit-test entry instead of
   the app entrypoint. Results stream to the simulator log; you should
   see one `[PASS]` line per `(:test)` function. The current suite
   covers:

   - `SensorAggregatorTests.testAccelBuffer` — push/inspect accelerometer buffer.
   - `SensorAggregatorTests.testPressureBuffer` — push/inspect pressure buffer.
   - `SensorAggregatorTests.testPositionBuffer` — push/inspect GPS buffer, oldest-first window.
   - `SensorAggregatorTests.testRingOverwrite` — counts cap at capacity across all three rings.
   - `JumpDetectorTests.testDetectsJump` — synthetic takeoff / airborne / landing profile.

---

## 4. Run the app in the simulator

Same build as step 1, but launch via `monkeydo` without `-t`:

```bash
# Build
monkeyc -y ~/.Garmin/connect_iq_dev_key.der \
         -o build/app.prg \
         -d instinct2 \
         -f monkey.jungle

# Open simulator
open -a ConnectIQ

# Run app
monkeydo build/app.prg instinct2
```

The simulator boots into the `instinct2` virtual watch, loads the app,
and the same launch flow as a side-loaded device. Use the simulator
keyboard shortcuts (or the on-screen START button) to navigate views.

---

## 5. Injecting simulator sensors

The Connect IQ simulator has a **Sensors** menu that lets you
manually feed accelerometer, pressure, and GPS samples into the
running app. This is the only way to exercise the live sensor
pipeline without a physical watch.

- **Accelerometer**: *Simulator → Sensors → Accelerometer*. Drag the
  X/Y/Z sliders to emulate static G, or use the "Motion" presets to
  shake the virtual watch.
- **Barometric pressure**: *Simulator → Sensors → Barometer*. Enter a
  pressure in Pa; values below the current reading simulate altitude
  gain.
- **GPS**: *Simulator → Position*. Enter a lat/lon pair and the
  simulator will feed it as the next GPS fix.

Important caveats:

- The simulator's accelerometer runs at a much lower rate than the
  real device, so threshold-dependent code paths (like
  `JumpDetector.onAccelSample`) may need several manual samples before
  the detector transitions through its states.
- There is no scriptable sensor harness for the public SDK. To get
  reproducible multi-sample sequences, prefer the unit-test suite in
  `source/test/` — it feeds the detector directly through the public
  API and does not require any simulator interaction.

---

## 6. Where the tests live

```
source/
  App.mc
  SensorAggregator.mc
  JumpDetector.mc
  ...
  test/
    SensorAggregatorTests.mc    # ring-buffer behaviour
    JumpDetectorTests.mc        # state-machine transition
```

Files under `source/test/` are part of the regular source tree, but
the `(:test)` annotation marks each function so only the
`--unit-test` build compiles them.

---

## 7. Adding new tests

1. Pick the right file (or add a new one) under `source/test/`.
2. Mark each function with `(:test)` and the
   `(logger as Test.Logger) as Boolean` signature.
3. Use `Test.assert(condition, message)` for each invariant you want
   to verify. `monkeydo -t` will surface a failure if any assertion
   fires.
4. Keep tests self-contained: build a fresh `SensorAggregator` and
   `JumpDetector` inside each test rather than reusing fixtures. The
   state machine is small enough that setup cost is negligible.

---

## Quick checklist

- [ ] `monkeyc … -f monkey.jungle` prints `BUILD SUCCESSFUL` and produces `build/app.prg`.
- [ ] `monkeyc … -f monkey.jungle --unit-test` prints `BUILD SUCCESSFUL` and produces `build/test.prg`.
- [ ] `open -a ConnectIQ` launches the simulator.
- [ ] `monkeydo build/test.prg instinct2 -t` reports each `(:test)` function as PASS.
- [ ] `monkeydo build/app.prg instinct2` boots into the Kite Tracker UI.
