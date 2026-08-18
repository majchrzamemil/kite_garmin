// JumpDetectorTests
//
// Unit tests for source/JumpDetector.mc. Drives the state machine
// through a synthetic takeoff / flight / landing sequence using only
// the public SensorAggregator + JumpDetector API. No real sensors or
// GPS are required, so the tests run entirely in the simulator.
//
// Run in the Connect IQ simulator via:
//
//   monkeyc -o build/test.prg -d instinct2 -f monkey.jungle --unit-test
//   monkeydo build/test.prg instinct2 -t
//
// See docs/TESTING.md for the full workflow.

import Toybox.Lang;
import Toybox.Test;

// Feed a synthetic takeoff + airborne + landing profile and assert that
// the detector emits a completed jump.
//
// Acceleration profiles are computed so the total-G magnitude crosses
// the detector thresholds:
//
//   total-G = sqrt(x^2 + y^2 + z^2) / 9.80665
//
//   rest       (z =  9.80665) -> 1.000 G
//   takeoff    (z = 14.0    ) -> 1.428 G  (above 1.4 G threshold)
//   airborne   (z =  5.0    ) -> 0.510 G  (below 1.15 G landing threshold)
//
// Pressure sequence:
//
//   baseline   = 101325 Pa
//   climb peak = 101225 Pa   (lower Pa = higher altitude; recorded as
//                             _minPressure; ~100 Pa below baseline ≈ ~8 m
//                             altitude gain via the ICAO formula)
//   landing    = 101320 Pa   (within 5 Pa of baseline, well inside the
//                             50 Pa PRESSURE_RETURN_PA corroboration window)
(:test)
function testDetectsJump(logger as Test.Logger) as Boolean {
    var agg     = new SensorAggregator();
    var detector = new JumpDetector(agg);

    // --- Baseline state --------------------------------------------------
    // Push 3 baseline accel samples first so the detector will transition
    // out of IDLE on its first onAccelSample call (it requires
    // getAccelCount() >= TAKEOFF_SAMPLES = 3 before leaving IDLE).
    agg.pushAccel(0.0, 0.0, 9.80665, 0);
    agg.pushAccel(0.0, 0.0, 9.80665, 100);
    agg.pushAccel(0.0, 0.0, 9.80665, 200);
    agg.pushPressure(101325, 200);                      // sea-level baseline
    agg.pushPosition(45.0 as Double, -73.0 as Double, 200); // GPS baseline

    // --- IDLE -> ARMED ---------------------------------------------------
    detector.onAccelSample(0.0, 0.0, 9.80665, 300);  // 1.000 G, ARMED
    detector.onAccelSample(0.0, 0.0, 9.80665, 400);  // 1.000 G, ARMED
    detector.onAccelSample(0.0, 0.0, 9.80665, 500);  // 1.000 G, ARMED

    Test.assert(detector.getState() == JumpDetector.STATE_ARMED);

    // --- ARMED -> AIRBORNE (takeoff spike) -------------------------------
    detector.onAccelSample(0.0, 0.0, 22.0, 600);    // 2.243 G, _aboveCount = 1
    detector.onAccelSample(0.0, 0.0, 22.0, 700);    // 2.243 G, _aboveCount = 2
    detector.onAccelSample(0.0, 0.0, 22.0, 800);    // 2.243 G -> AIRBORNE

    Test.assert(detector.getState() == JumpDetector.STATE_AIRBORNE);

    // --- AIRBORNE: simulated climb --------------------------------------
    // Hold airborne for ~1.5s so MIN_FLIGHT_MS (1000ms) elapses, with a
    // 100 Pa pressure drop to satisfy the hybrid filter (>=20 Pa) and
    // ~8.3 m climb at peak. Then return to baseline so the pressure
    // path fires with a flat descent rate.
    agg.pushPressure(101300, 900);
    detector.onAccelSample(0.0, 0.0, 5.0, 900);     // 0.510 G, _belowCount = 1,
                                                  // _minPressure = 101300

    agg.pushPressure(101225, 1000);
    detector.onAccelSample(0.0, 0.0, 5.0, 1000);    // 0.510 G, _belowCount = 2,
                                                  // _minPressure = 101225

    // Hold the peak for several ticks (all dedup against 101225 in the
    // ring). _belowCount keeps climbing but MIN_FLIGHT_MS blocks
    // landing until t>=1800.
    for (var t = 1100; t < 2000; t += 100) {
        detector.onAccelSample(0.0, 0.0, 5.0, t);
    }

    // Return close to baseline (within 20 Pa) so pressureReturned=true.
    agg.pushPressure(101325, 2000);
    detector.onAccelSample(0.0, 0.0, 5.0, 2000);

    // Hold at baseline so the descent rate (oldest 101325@t=800 vs
    // newest 101325@t=2000) computes to 0 Pa/s, satisfying descentFlat.
    for (var t = 2100; t <= 2400; t += 100) {
        detector.onAccelSample(0.0, 0.0, 5.0, t);
    }

    // --- Verify a jump was recorded -------------------------------------
    var jump = detector.getLastJump();
    Test.assert(jump != null);

    if (jump == null) { return false; }
    Test.assert(jump[:durationMs] >= 0);
    Test.assert(jump[:heightM] >= 0);
    Test.assert(jump[:lengthM] >= 0);
    Test.assert(jump[:startTs] > 0);
    Test.assert(jump[:endTs] >= jump[:startTs]);
    Test.assert(jump[:peakDeltaPa] > 0);

    // Height must reflect the ~100 Pa climb, not collapse to ~0.
    // ICAO formula on a 100 Pa drop yields ~8.3 m; allow generous slack.
    Test.assert(jump[:heightM] > 5);
    Test.assert(jump[:heightM] < 15);
    // Sanity: height in metres should track the pressure delta (about
    // 12 Pa per metre at sea level) within a factor of 2x. A jump
    // registered with peakDeltaPa=100 must not collapse to heightM=0.
    var peakDelta = jump[:peakDeltaPa];
    Test.assert(peakDelta >= 80 && peakDelta <= 120);
    var heightPerPa = jump[:heightM].toFloat() / peakDelta.toFloat();
    Test.assert(heightPerPa > 0.04 && heightPerPa < 0.20);

    return true;
}

(:test)
function testPressureRate1Hz(logger as Test.Logger) as Boolean {
    var agg = new SensorAggregator();
    var det = new JumpDetector(agg);

    // Baseline pressure and accel so IDLE -> ARMED on first detector call.
    agg.pushPressure(101325, 0);
    agg.pushPressure(101325, 1000);
    agg.pushAccel(0.0, 0.0, 9.80665, 0);
    agg.pushAccel(0.0, 0.0, 9.80665, 100);
    agg.pushAccel(0.0, 0.0, 9.80665, 200);
    det.onAccelSample(0.0, 0.0, 9.80665, 0);
    det.onAccelSample(0.0, 0.0, 9.80665, 100);
    det.onAccelSample(0.0, 0.0, 9.80665, 200);
    // Now state == ARMED.

    // Takeoff: 3 high-G samples (g=2.039).
    det.onAccelSample(20.0, 0.0, 0.0, 1000);
    det.onAccelSample(20.0, 0.0, 0.0, 1100);
    det.onAccelSample(20.0, 0.0, 0.0, 1200);
    // Now state == AIRBORNE.

    // Push peak-low pressure (100 Pa drop = ~8 m climb).
    agg.pushPressure(101225, 1200);

    // Airborne: low-G samples for ~2 seconds.
    for (var t = 1300; t < 3300; t += 100) {
        det.onAccelSample(2.0, 0.0, 0.0, t);
    }

    // Pressure back to baseline (triggers landing via pressureOK).
    agg.pushPressure(101325, 3300);

    // One more low-G sample so _maybeLand fires with the new pressure.
    det.onAccelSample(2.0, 0.0, 0.0, 3400);

    var jump = det.getLastJump();
    if (jump == null) {
        logger.debug("Expected jump detected with 1Hz pressure");
        return false;
    }
    var heightM = jump[:heightM];
    if (heightM == null || heightM.toFloat() <= 5.0) {
        logger.debug("Expected heightM > 5, got " + heightM);
        return false;
    }
    logger.debug("testPressureRate1Hz: heightM=" + heightM);
    return true;
}

(:test)
function testFlatPressure(logger as Test.Logger) as Boolean {
    var agg = new SensorAggregator();
    var det = new JumpDetector(agg);

    // Push baseline pressure so the hybrid filter's pressure-drop gate
    // (>= 20 Pa) does not discard the jump. We then push a 40 Pa drop
    // during the flight and NEVER return to baseline, so
    // pressureReturned stays false and the pressure path cannot win;
    // the stationary GPS path is the only way to land.
    agg.pushPressure(101325, 0);
    agg.pushPosition(51.5 as Double, -0.1 as Double, 0);
    agg.pushPosition(51.5 as Double, -0.1 as Double, 500);
    agg.pushPosition(51.5 as Double, -0.1 as Double, 1500);
    agg.pushPosition(51.5 as Double, -0.1 as Double, 2000);
    agg.pushPosition(51.5 as Double, -0.1 as Double, 2400);
    agg.pushPosition(51.5 as Double, -0.1 as Double, 3000);

    // Baseline accel.
    agg.pushAccel(0.0, 0.0, 9.80665, 0);
    agg.pushAccel(0.0, 0.0, 9.80665, 100);
    agg.pushAccel(0.0, 0.0, 9.80665, 200);
    det.onAccelSample(0.0, 0.0, 9.80665, 0);
    det.onAccelSample(0.0, 0.0, 9.80665, 100);
    det.onAccelSample(0.0, 0.0, 9.80665, 200);
    // Now state == ARMED.

    // Takeoff: 3 high-G samples.
    det.onAccelSample(20.0, 0.0, 0.0, 500);
    det.onAccelSample(20.0, 0.0, 0.0, 600);
    det.onAccelSample(20.0, 0.0, 0.0, 700);
    // Now state == AIRBORNE.

    // Pressure drops 40 Pa during the flight (hybrid filter satisfied,
    // but |current - baseline| > 20 Pa so pressureReturned stays false).
    agg.pushPressure(101285, 800);

    // Airborne: low-G samples. GPS speed is 0 (all positions identical),
    // so once MIN_FLIGHT_MS (1000 ms) elapses, the GPS path fires via
    // gpsSlowForLongEnough.
    for (var t = 800; t < 3000; t += 100) {
        det.onAccelSample(2.0, 0.0, 0.0, t);
    }

    var jump = det.getLastJump();
    if (jump == null) {
        logger.debug("Expected jump detected via GPS path");
        return false;
    }
    var lpc = jump.get(:landingPathCode);
    if (lpc == null || !lpc.equals(1)) {
        logger.debug("Expected landingPathCode=1 (gps), got " + lpc);
        return false;
    }
    var heightM = jump[:heightM];
    if (heightM == null || heightM.toFloat() <= 0.0) {
        logger.debug("Expected heightM > 0 with 40 Pa drop, got " + heightM);
        return false;
    }
    logger.debug("testFlatPressure: confirmed GPS path landingPathCode=" + lpc + " heightM=" + heightM);
    return true;
}

(:test)
function testSubMeterJump(logger as Test.Logger) as Boolean {
    var agg = new SensorAggregator();
    var det = new JumpDetector(agg);

    // Baseline pressure.
    agg.pushPressure(101325, 0);
    agg.pushPosition(45.0 as Double, -73.0 as Double, 0);

    // Baseline accel.
    agg.pushAccel(0.0, 0.0, 9.80665, 0);
    agg.pushAccel(0.0, 0.0, 9.80665, 100);
    agg.pushAccel(0.0, 0.0, 9.80665, 200);
    det.onAccelSample(0.0, 0.0, 9.80665, 0);
    det.onAccelSample(0.0, 0.0, 9.80665, 100);
    det.onAccelSample(0.0, 0.0, 9.80665, 200);
    // Now state == ARMED.

    // Takeoff: 3 high-G samples.
    det.onAccelSample(20.0, 0.0, 0.0, 500);
    det.onAccelSample(20.0, 0.0, 0.0, 600);
    det.onAccelSample(20.0, 0.0, 0.0, 700);
    // Now state == AIRBORNE.

    // Push tiny pressure drop (5 Pa = ~0.4 m, below the 20 Pa hybrid gate).
    agg.pushPressure(101320, 800);

    // Stay airborne for >= 1.5 s with low-G samples. The detector must
    // discard this jump because pressureDrop (5 Pa) is below the
    // TAKEOFF_PRESSURE_DROP_PA (20) hybrid gate.
    // g = sqrt(2^2 + 0 + 9.80665^2)/9.80665 ~= 1.020, which is BELOW
    // FREEFALL_G (1.05) so freefall would otherwise confirm, and BELOW
    // LANDING_G (1.15) so _belowCount rises. But the discard fires
    // before any landing path can win once MIN_FLIGHT_MS elapses.
    for (var t = 800; t < 2500; t += 100) {
        det.onAccelSample(2.0, 0.0, 9.80665, t);
    }

    var jump = det.getLastJump();
    if (jump != null) {
        logger.debug("Expected sub-meter jump to be discarded (drop < 20 Pa), got: " + jump);
        return false;
    }
    if (det.getState() == JumpDetector.STATE_AIRBORNE) {
        logger.debug("Detector still AIRBORNE; should have re-armed after discard");
        return false;
    }
    logger.debug("testSubMeterJump: confirmed sub-meter jump discarded by hybrid gate");
    return true;
}

(:test)
function testIgnoresWristFlick(logger as Test.Logger) as Boolean {
    var agg = new SensorAggregator();
    var det = new JumpDetector(agg);

    // Baseline.
    agg.pushAccel(0.0, 0.0, 9.80665, 0);
    agg.pushAccel(0.0, 0.0, 9.80665, 100);
    agg.pushAccel(0.0, 0.0, 9.80665, 200);
    agg.pushPressure(101325, 0);
    agg.pushPosition(45.0 as Double, -73.0 as Double, 0);
    det.onAccelSample(0.0, 0.0, 9.80665, 0);
    det.onAccelSample(0.0, 0.0, 9.80665, 100);
    det.onAccelSample(0.0, 0.0, 9.80665, 200);

    // Brief high-G spike — triggers ARMED -> AIRBORNE.
    det.onAccelSample(22.0, 0.0, 0.0, 500);
    det.onAccelSample(22.0, 0.0, 0.0, 600);
    det.onAccelSample(22.0, 0.0, 0.0, 700);

    // Samples keep total-G > FREEFALL_G (1.05) so no freefall confirmation.
    // (0, 0, 10.5) gives g = 10.5 / 9.80665 ~= 1.071 (> 1.05).
    for (var t = 800; t < 2000; t += 100) {
        det.onAccelSample(0.0, 0.0, 10.5, t);
    }

    var jump = det.getLastJump();
    if (jump != null) {
        logger.debug("Wrist flick should not produce a jump, got: " + jump);
        return false;
    }
    logger.debug("testIgnoresWristFlick: correctly ignored wrist flick");
    return true;
}

(:test)
function testBriefFreefallDoesNotTrigger(logger as Test.Logger) as Boolean {
    var agg = new SensorAggregator();
    var det = new JumpDetector(agg);

    agg.pushAccel(0.0, 0.0, 9.80665, 0);
    agg.pushAccel(0.0, 0.0, 9.80665, 100);
    agg.pushAccel(0.0, 0.0, 9.80665, 200);
    agg.pushPressure(101325, 0);
    agg.pushPosition(45.0 as Double, -73.0 as Double, 0);
    det.onAccelSample(0.0, 0.0, 9.80665, 0);
    det.onAccelSample(0.0, 0.0, 9.80665, 100);
    det.onAccelSample(0.0, 0.0, 9.80665, 200);

    // Takeoff.
    det.onAccelSample(22.0, 0.0, 0.0, 500);
    det.onAccelSample(22.0, 0.0, 0.0, 600);
    det.onAccelSample(22.0, 0.0, 0.0, 700);

    // Single sample of freefall (g < 1.05), then back to g > 1.15 so the
    // landing branch never accumulates _belowCount.
    // g = sqrt(2^2 + 0^2 + 9^2) / 9.80665 = sqrt(85) / 9.80665 ~= 0.94 (< 1.05)
    det.onAccelSample(2.0, 0.0, 9.0, 800);
    // (0, 0, 11.5) -> g ~= 1.173 (> LANDING_G 1.15, > FREEFALL_G 1.05).
    det.onAccelSample(0.0, 0.0, 11.5, 900);
    det.onAccelSample(0.0, 0.0, 11.5, 1000);
    det.onAccelSample(0.0, 0.0, 11.5, 1100);
    det.onAccelSample(0.0, 0.0, 11.5, 1200);
    // More samples staying above LANDING_G. With FREEFALL_SAMPLES=1 the
    // single freefall sample at t=800 sets _freefallConfirmed=true. Once
    // _belowCount reaches LANDING_SAMPLES (3) the detector would land,
    // so we keep g > LANDING_G (1.15) here to keep _belowCount reset.
    for (var t = 1300; t < 2000; t += 100) {
        det.onAccelSample(0.0, 0.0, 11.5, t);
    }

    var jump = det.getLastJump();
    if (jump != null) {
        logger.debug("Brief freefall should not trigger, got jump: " + jump);
        return false;
    }
    logger.debug("testBriefFreefallDoesNotTrigger: correctly ignored brief freefall");
    return true;
}

// ----------------------------------------------------------------------
// Regression tests for the crash that occurred after the second jump.
// These exercise the defensive code added to source/JumpDetector.mc:
//   - _modPositive() guard in _descentRatePaS
//   - pressure-history ring reset on each new AIRBORNE
//   - landingPath reset / "unknown" default in _enterLanding
//   - try/catch around _lastJump creation
//   - _pressureHistorySize >= 2 gate before evaluating descentFlat
//   - forced timeout landing after MAX_FLIGHT_MS
// ----------------------------------------------------------------------

// Simulates a perfectly smooth landing: total-G stays at 1.0 throughout
// (no impact spike). Pressure drops 60 Pa, returns to baseline, and the
// descent-rate helper sees a flat line. The detector should declare the
// jump via the "pressure" path.
(:test)
function testSmoothLandingPressureOnly(logger as Test.Logger) as Boolean {
    var agg = new SensorAggregator();
    var det = new JumpDetector(agg);

    // Baseline.
    agg.pushAccel(0.0, 0.0, 9.80665, 0);
    agg.pushAccel(0.0, 0.0, 9.80665, 100);
    agg.pushAccel(0.0, 0.0, 9.80665, 200);
    agg.pushPressure(101325, 0);
    agg.pushPosition(45.0 as Double, -73.0 as Double, 0);
    det.onAccelSample(0.0, 0.0, 9.80665, 0);
    det.onAccelSample(0.0, 0.0, 9.80665, 100);
    det.onAccelSample(0.0, 0.0, 9.80665, 200);

    // Takeoff: 3 high-G samples -> AIRBORNE.
    det.onAccelSample(22.0, 0.0, 0.0, 500);
    det.onAccelSample(22.0, 0.0, 0.0, 600);
    det.onAccelSample(22.0, 0.0, 0.0, 700);

    if (det.getState() != JumpDetector.STATE_AIRBORNE) {
        logger.debug("Did not enter AIRBORNE");
        return false;
    }

    // Climb: pressure drops 60 Pa. Keep total-G at 1.10 G (z = 10.787) so
    // the low-G path stays ineligible: 1.10 > FREEFALL_G (1.05) so
    // freefall never gets confirmed, and _belowCount increments but
    // cannot fire lowG without freefall.
    agg.pushPressure(101265, 800);
    for (var t = 800; t < 1900; t += 100) {
        det.onAccelSample(0.0, 0.0, 10.787, t);
    }

    // Return to baseline: delta from 101325 -> 101325 = 0 <= 15, so
    // pressureReturned becomes true. The descent rate between the oldest
    // sample (baseline at takeoff) and the newest (baseline at return) is
    // 0 Pa/s, so descentFlat is true. Pressure path fires.
    agg.pushPressure(101325, 1900);
    det.onAccelSample(0.0, 0.0, 9.80665, 2000);

    var jump = det.getLastJump();
    if (jump == null) {
        logger.debug("testSmoothLandingPressureOnly: no jump recorded");
        return false;
    }
    var lpc = jump.get(:landingPathCode);
    if (lpc == null || !lpc.equals(0)) {
        logger.debug("Expected landingPathCode=0 (pressure), got " + lpc);
        return false;
    }
    logger.debug("testSmoothLandingPressureOnly: landingPathCode=" + lpc);
    return true;
}

// Existing hard-landing profile (3 low-G samples + freefall confirmation)
// with pressure kept below baseline throughout the flight so the pressure
// path cannot fire. The detector must fall back to the lowG path.
(:test)
function testHardLandingLowGPath(logger as Test.Logger) as Boolean {
    var agg = new SensorAggregator();
    var det = new JumpDetector(agg);

    agg.pushAccel(0.0, 0.0, 9.80665, 0);
    agg.pushAccel(0.0, 0.0, 9.80665, 100);
    agg.pushAccel(0.0, 0.0, 9.80665, 200);
    agg.pushPressure(101325, 200);
    agg.pushPosition(45.0 as Double, -73.0 as Double, 200);
    det.onAccelSample(0.0, 0.0, 9.80665, 0);
    det.onAccelSample(0.0, 0.0, 9.80665, 100);
    det.onAccelSample(0.0, 0.0, 9.80665, 200);

    det.onAccelSample(22.0, 0.0, 0.0, 500);
    det.onAccelSample(22.0, 0.0, 0.0, 600);
    det.onAccelSample(22.0, 0.0, 0.0, 700);

    // Pressure drops 100 Pa during the jump (>= 20 Pa hybrid gate).
    // Freefall sample confirms on the first low-G tick.
    agg.pushPressure(101225, 800);
    det.onAccelSample(0.0, 0.0, 5.0, 800); // 0.510 G -> freefall confirmed

    // Hold airborne through the MIN_FLIGHT_MS (1000 ms) mark with low-G
    // samples so _belowCount stays high.
    det.onAccelSample(0.0, 0.0, 5.0, 900);
    det.onAccelSample(0.0, 0.0, 5.0, 1000);
    det.onAccelSample(0.0, 0.0, 5.0, 1100);
    det.onAccelSample(0.0, 0.0, 5.0, 1200);
    det.onAccelSample(0.0, 0.0, 5.0, 1300);
    det.onAccelSample(0.0, 0.0, 5.0, 1400);
    det.onAccelSample(0.0, 0.0, 5.0, 1500);
    det.onAccelSample(0.0, 0.0, 5.0, 1600);
    det.onAccelSample(0.0, 0.0, 5.0, 1700);

    // Fast return to 15 Pa below baseline so pressureReturned becomes
    // true (|15| <= 20) but the descent rate across the ring
    // (101325@700 -> 101310@1750 = -14.3 Pa/s, |rate| > 5) keeps
    // descentFlat false, letting the lowG path win instead of the
    // pressure path.
    agg.pushPressure(101310, 1750);
    det.onAccelSample(0.0, 0.0, 5.0, 1800); // lowG fires (pressureReturned=true, descentFlat=false)

    var jump = det.getLastJump();
    if (jump == null) {
        logger.debug("testHardLandingLowGPath: no jump recorded");
        return false;
    }
    var lpc = jump.get(:landingPathCode);
    if (lpc == null || !lpc.equals(2)) {
        logger.debug("Expected landingPathCode=2 (lowG), got " + lpc);
        return false;
    }
    logger.debug("testHardLandingLowGPath: landingPathCode=" + lpc);
    return true;
}

// Reproduces the real-watch crash scenario: two consecutive jumps in
// the same session. First jump lands hard via lowG, second jump lands
// smoothly via pressure. The detector must record both without crashing.
(:test)
function testTwoConsecutiveJumps(logger as Test.Logger) as Boolean {
    var agg = new SensorAggregator();
    var det = new JumpDetector(agg);

    agg.pushAccel(0.0, 0.0, 9.80665, 0);
    agg.pushAccel(0.0, 0.0, 9.80665, 100);
    agg.pushAccel(0.0, 0.0, 9.80665, 200);
    agg.pushPressure(101325, 200);
    agg.pushPosition(45.0 as Double, -73.0 as Double, 200);
    det.onAccelSample(0.0, 0.0, 9.80665, 0);
    det.onAccelSample(0.0, 0.0, 9.80665, 100);
    det.onAccelSample(0.0, 0.0, 9.80665, 200);

    // --- Jump 1: hard landing via lowG ---
    det.onAccelSample(22.0, 0.0, 0.0, 500);
    det.onAccelSample(22.0, 0.0, 0.0, 600);
    det.onAccelSample(22.0, 0.0, 0.0, 700);

    // 100 Pa drop during flight (>= 20 Pa hybrid gate); freefall
    // confirmed on the first low-G tick.
    agg.pushPressure(101225, 800);
    det.onAccelSample(0.0, 0.0, 5.0, 800);
    det.onAccelSample(0.0, 0.0, 5.0, 900);
    det.onAccelSample(0.0, 0.0, 5.0, 1000);
    det.onAccelSample(0.0, 0.0, 5.0, 1100);
    det.onAccelSample(0.0, 0.0, 5.0, 1200);
    det.onAccelSample(0.0, 0.0, 5.0, 1300);
    det.onAccelSample(0.0, 0.0, 5.0, 1400);
    det.onAccelSample(0.0, 0.0, 5.0, 1500);
    det.onAccelSample(0.0, 0.0, 5.0, 1600);
    det.onAccelSample(0.0, 0.0, 5.0, 1700);

    // Fast return to 15 Pa below baseline so pressureReturned=true
    // (|15| <= 20) but descentFlat=false (rate = -14.3 Pa/s > 5),
    // letting the lowG path win.
    agg.pushPressure(101310, 1750);
    det.onAccelSample(0.0, 0.0, 5.0, 1800); // lowG fires

    var jump1 = det.getLastJump();
    if (jump1 == null) {
        logger.debug("testTwoConsecutiveJumps: jump1 not recorded");
        return false;
    }
    var jump1Code = jump1.get(:landingPathCode);
    if (jump1Code == null || !jump1Code.equals(2)) {
        logger.debug("testTwoConsecutiveJumps: jump1 code=" + jump1Code);
        return false;
    }

    // Wait through COASTING (COAST_MS = 1500 ms). The detector should
    // re-arm itself on the first accel sample past _coastEndTs.
    var jump1EndTs = jump1.get(:endTs) as Number;
    var coastEnd = jump1EndTs + 1500;
    var t = jump1EndTs + 100;
    while (t < coastEnd + 200) {
        det.onAccelSample(0.0, 0.0, 9.80665, t);
        t += 100;
    }
    if (det.getState() != JumpDetector.STATE_ARMED) {
        logger.debug("testTwoConsecutiveJumps: did not rearm (state=" + det.getStateName() + ")");
        return false;
    }

    // --- Jump 2: smooth landing via pressure ---
    // Refresh baseline pressure before the second takeoff.
    agg.pushPressure(101325, t);

    det.onAccelSample(22.0, 0.0, 0.0, t + 100);
    det.onAccelSample(22.0, 0.0, 0.0, t + 200);
    det.onAccelSample(22.0, 0.0, 0.0, t + 300);

    // Climb 60 Pa, hold for >= 1.5s of airborne time, then return to
    // baseline. Use 1.10 G (z = 10.787) during the airborne hold so
    // neither freefall nor lowG triggers early.
    agg.pushPressure(101265, t + 400);
    var t2 = t + 400;
    while (t2 < t + 1800) {
        det.onAccelSample(0.0, 0.0, 10.787, t2);
        t2 += 100;
    }
    agg.pushPressure(101325, t + 1800);
    det.onAccelSample(0.0, 0.0, 9.80665, t + 1900);

    var jump2 = det.getLastJump();
    if (jump2 == null) {
        logger.debug("testTwoConsecutiveJumps: jump2 not recorded");
        return false;
    }
    var jump2Code = jump2.get(:landingPathCode);
    if (jump2Code == null || !jump2Code.equals(0)) {
        logger.debug("testTwoConsecutiveJumps: jump2 code=" + jump2Code);
        return false;
    }
    if (jump1EndTs >= (jump2.get(:startTs) as Number)) {
        logger.debug("testTwoConsecutiveJumps: jump2 did not start after jump1 ended");
        return false;
    }
    logger.debug("testTwoConsecutiveJumps: jump1 lowG (code=2), jump2 pressure (code=0), no crash");
    return true;
}

// Never let any landing path fire (no pressure return, no GPS slow, no
// freefall). Advance time past MAX_FLIGHT_MS (30 s). The detector must
// force a landing with landingPath="timeout".
(:test)
function testAirborneTimeout(logger as Test.Logger) as Boolean {
    var agg = new SensorAggregator();
    var det = new JumpDetector(agg);

    agg.pushAccel(0.0, 0.0, 9.80665, 0);
    agg.pushAccel(0.0, 0.0, 9.80665, 100);
    agg.pushAccel(0.0, 0.0, 9.80665, 200);
    agg.pushPressure(101325, 0);
    agg.pushPosition(45.0 as Double, -73.0 as Double, 0);
    det.onAccelSample(0.0, 0.0, 9.80665, 0);
    det.onAccelSample(0.0, 0.0, 9.80665, 100);
    det.onAccelSample(0.0, 0.0, 9.80665, 200);

    det.onAccelSample(22.0, 0.0, 0.0, 500);
    det.onAccelSample(22.0, 0.0, 0.0, 600);
    det.onAccelSample(22.0, 0.0, 0.0, 700);

    // Keep pressure below baseline so pressureReturned is false. Keep
    // total-G between FREEFALL_G (1.05) and LANDING_G (1.15) so that
    // _belowCount increments (lowG eligible) but _freefallConfirmed
    // never gets set. Use 1.10 G = (0, 0, 10.787).
    agg.pushPressure(101225, 800);
    var t = 800;
    while (t < 35000) {
        det.onAccelSample(0.0, 0.0, 10.787, t);
        // Drive the timeout via tick() the same way pollPressure() does
        // in production. tick() advances the airborne watchdog.
        det.tick(t);
        t += 500;
    }

    var jump = det.getLastJump();
    if (jump == null) {
        logger.debug("testAirborneTimeout: no jump recorded after 30s");
        return false;
    }
    var lpc = jump.get(:landingPathCode);
    if (lpc == null || !lpc.equals(3)) {
        logger.debug("Expected landingPathCode=3 (timeout), got " + lpc);
        return false;
    }
    logger.debug("testAirborneTimeout: landingPathCode=" + lpc + " endTs=" + jump.get(:endTs));
    return true;
}

// Feed more than PRESSURE_HISTORY_SIZE unique pressure samples during
// the airborne phase so the ring head wraps past the buffer boundary.
// The descent-rate helper must not crash, and the detector must
// continue to function normally.
(:test)
function testPressureHistoryWrapAround(logger as Test.Logger) as Boolean {
    var agg = new SensorAggregator();
    var det = new JumpDetector(agg);

    agg.pushAccel(0.0, 0.0, 9.80665, 0);
    agg.pushAccel(0.0, 0.0, 9.80665, 100);
    agg.pushAccel(0.0, 0.0, 9.80665, 200);
    agg.pushPressure(101325, 0);
    agg.pushPosition(45.0 as Double, -73.0 as Double, 0);
    det.onAccelSample(0.0, 0.0, 9.80665, 0);
    det.onAccelSample(0.0, 0.0, 9.80665, 100);
    det.onAccelSample(0.0, 0.0, 9.80665, 200);

    det.onAccelSample(22.0, 0.0, 0.0, 500);
    det.onAccelSample(22.0, 0.0, 0.0, 600);
    det.onAccelSample(22.0, 0.0, 0.0, 700);

    // Feed 10 alternating pressure samples so head wraps past
    // PRESSURE_HISTORY_SIZE (4) multiple times. Each sample is unique
    // relative to its predecessor so dedup does not skip them.
    var t = 800;
    var i = 0;
    while (i < 10) {
        var pa = (i % 2 == 0) ? 101225 : 101325;
        agg.pushPressure(pa, t);
        det.onAccelSample(0.0, 0.0, 9.80665, t);
        t += 200;
        i++;
    }

    // If we got here without crashing, the wraparound is safe. Now
    // finish with a lowG landing to verify normal state-machine exit.
    agg.pushPressure(101225, t);
    det.onAccelSample(0.0, 0.0, 5.0, t);
    det.onAccelSample(0.0, 0.0, 5.0, t + 100);
    det.onAccelSample(0.0, 0.0, 5.0, t + 200);

    var jump = det.getLastJump();
    if (jump == null) {
        logger.debug("testPressureHistoryWrapAround: no jump after wraparound");
        return false;
    }
    logger.debug("testPressureHistoryWrapAround: jump recorded after wrap, code=" + jump.get(:landingPathCode));
    return true;
}

// Enter AIRBORNE without any pressure data available. The pressure
// history ring is therefore empty (size=0). A lowG landing should
// still complete _enterLanding() without crashing.
(:test)
function testEmptyPressureHistoryDoesNotCrash(logger as Test.Logger) as Boolean {
    var agg = new SensorAggregator();
    var det = new JumpDetector(agg);

    // Push baseline pressure so the hybrid filter's pressure-drop gate
    // (>= 20 Pa) does not discard the jump. The pressure is then held
    // 40 Pa below baseline for the entire flight so pressureReturned
    // stays false and the pressure path cannot win. The descent-rate
    // helper must also not crash on the seeded history ring.
    agg.pushPressure(101325, 200);
    // Two identical GPS fixes 600 ms apart so the GPS path
    // corroborates stationary riding.
    agg.pushAccel(0.0, 0.0, 9.80665, 0);
    agg.pushAccel(0.0, 0.0, 9.80665, 100);
    agg.pushAccel(0.0, 0.0, 9.80665, 200);
    agg.pushPosition(45.0 as Double, -73.0 as Double, 0);
    agg.pushPosition(45.0 as Double, -73.0 as Double, 600);
    det.onAccelSample(0.0, 0.0, 9.80665, 0);
    det.onAccelSample(0.0, 0.0, 9.80665, 100);
    det.onAccelSample(0.0, 0.0, 9.80665, 200);

    det.onAccelSample(22.0, 0.0, 0.0, 500);
    det.onAccelSample(22.0, 0.0, 0.0, 600);
    det.onAccelSample(22.0, 0.0, 0.0, 700);

    if (det.getState() != JumpDetector.STATE_AIRBORNE) {
        logger.debug("testEmptyPressureHistoryDoesNotCrash: not airborne");
        return false;
    }

    // Drop pressure 40 Pa below baseline; do not return to baseline so
    // pressureReturned stays false. GPS has been slow since before
    // takeoff (last two positions are identical at t=0, t=600); we
    // keep feeding low-G samples until both MIN_FLIGHT_MS (1000 ms)
    // and the 500 ms GPS-low duration are satisfied so the gps path
    // wins ahead of lowG.
    agg.pushPressure(101285, 800);

    det.onAccelSample(0.0, 0.0, 5.0, 800);
    det.onAccelSample(0.0, 0.0, 5.0, 900);
    det.onAccelSample(0.0, 0.0, 5.0, 1000);
    det.onAccelSample(0.0, 0.0, 5.0, 1100);
    det.onAccelSample(0.0, 0.0, 5.0, 1200);
    det.onAccelSample(0.0, 0.0, 5.0, 1300);
    det.onAccelSample(0.0, 0.0, 5.0, 1400);
    det.onAccelSample(0.0, 0.0, 5.0, 1500);
    det.onAccelSample(0.0, 0.0, 5.0, 1600);
    det.onAccelSample(0.0, 0.0, 5.0, 1700);
    det.onAccelSample(0.0, 0.0, 5.0, 1800);
    det.onAccelSample(0.0, 0.0, 5.0, 1900);
    det.onAccelSample(0.0, 0.0, 5.0, 2000);
    det.onAccelSample(0.0, 0.0, 5.0, 2100);
    det.onAccelSample(0.0, 0.0, 5.0, 2200);
    det.onAccelSample(0.0, 0.0, 5.0, 2300);
    det.onAccelSample(0.0, 0.0, 5.0, 2400);

    var jump = det.getLastJump();
    if (jump == null) {
        logger.debug("testEmptyPressureHistoryDoesNotCrash: no jump recorded");
        return false;
    }
    var lpc = jump.get(:landingPathCode);
    if (lpc == null || !lpc.equals(1)) {
        logger.debug("Expected landingPathCode=1 (gps), got " + lpc);
        return false;
    }
    logger.debug("testEmptyPressureHistoryDoesNotCrash: landingPathCode=" + lpc);
    return true;
}
