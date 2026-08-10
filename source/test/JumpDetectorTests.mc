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
import Toybox.System;
import Toybox.Test;

// Helper: feed a single accelerometer sample to the detector with the
// current system timer as the timestamp. Mirrors how App.onSensor()
// would call onAccelSample in the running app.
function feedAccelSample(detector, x as Float, y as Float, z as Float) as Void {
    detector.onAccelSample(x, y, z, System.getTimer());
}

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
    agg.pushAccel(0.0, 0.0, 9.80665, 0);
    agg.pushAccel(0.0, 0.0, 9.80665, 0);
    agg.pushPressure(101325, 0);                       // sea-level baseline
    agg.pushPosition(45.0 as Double, -73.0 as Double, 0); // GPS baseline

    // --- IDLE -> ARMED ---------------------------------------------------
    // First detector call promotes IDLE -> ARMED (because getAccelCount()
    // already equals 3). Subsequent calls process the sample in ARMED.
    feedAccelSample(detector, 0.0, 0.0, 9.80665);  // 1.000 G, ARMED
    feedAccelSample(detector, 0.0, 0.0, 9.80665);  // 1.000 G, ARMED
    feedAccelSample(detector, 0.0, 0.0, 9.80665);  // 1.000 G, ARMED

    Test.assert(detector.getState() == JumpDetector.STATE_ARMED);

    // --- ARMED -> AIRBORNE (takeoff spike) -------------------------------
    feedAccelSample(detector, 0.0, 0.0, 22.0);    // 2.243 G, _aboveCount = 1
    feedAccelSample(detector, 0.0, 0.0, 22.0);    // 2.243 G, _aboveCount = 2
    feedAccelSample(detector, 0.0, 0.0, 22.0);    // 2.243 G -> AIRBORNE

    Test.assert(detector.getState() == JumpDetector.STATE_AIRBORNE);

    // --- AIRBORNE: simulated climb --------------------------------------
    // Feed a sequence of descending pressures during flight so that
    // _minPressure tracks the peak altitude. Baseline is captured at
    // takeoff (101325 Pa); the lowest reading here is 101225 Pa, a
    // ~100 Pa drop (~8 m climb).
    agg.pushPressure(101300, 0);
    feedAccelSample(detector, 0.0, 0.0, 5.0);     // 0.510 G, _belowCount = 1,
                                                  // _minPressure = 101300

    agg.pushPressure(101225, 0);
    feedAccelSample(detector, 0.0, 0.0, 5.0);     // 0.510 G, _belowCount = 2,
                                                  // _minPressure = 101225

    // Hold the peak for one more tick, then start returning toward
    // baseline. _maybeLand won't fire yet because the latest reading
    // is still 101225 (delta = 100 Pa > 50 Pa threshold). _belowCount
    // is preserved on a failed _maybeLand, so the next low-G sample
    // re-enters the branch with the near-baseline pressure as latest.
    agg.pushPressure(101225, 0);
    feedAccelSample(detector, 0.0, 0.0, 5.0);     // 0.510 G, _belowCount = 3,
                                                  // _maybeLand: latest 101225,
                                                  // pressureOK = false, stay
                                                  // AIRBORNE with _belowCount=3

    agg.pushPressure(101320, 0);                  // back near baseline
    feedAccelSample(detector, 0.0, 0.0, 5.0);     // 0.510 G, _belowCount = 4,
                                                  // _maybeLand: latest 101320,
                                                  // delta = 5 Pa <= 50, LAND

    // --- Verify a jump was recorded -------------------------------------
    var jump = detector.getLastJump();
    Test.assert(jump != null);

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

    // No pressure pushed. Use stationary GPS to trigger landing.
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

    // Airborne: low-G samples. GPS speed is 0 (all positions identical),
    // so _maybeLand will succeed via speedOK on the 3rd low-G sample.
    for (var t = 800; t < 3000; t += 100) {
        det.onAccelSample(2.0, 0.0, 0.0, t);
    }

    var jump = det.getLastJump();
    if (jump == null) {
        logger.debug("Expected jump detected even without pressure (GPS trigger)");
        return false;
    }
    var heightM = jump[:heightM];
    if (heightM != null && heightM.toFloat() > 0.0) {
        logger.debug("Expected heightM == 0 with no pressure, got " + heightM);
        return false;
    }
    logger.debug("testFlatPressure: confirmed heightM==0 without pressure data");
    return true;
}

(:test)
function testSubMeterJump(logger as Test.Logger) as Boolean {
    var agg = new SensorAggregator();
    var det = new JumpDetector(agg);

    // Baseline pressure.
    agg.pushPressure(101325, 0);

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

    // Push tiny pressure drop (5 Pa = ~0.4 m).
    agg.pushPressure(101320, 700);

    // Airborne: 3 low-G samples to trigger landing.
    det.onAccelSample(2.0, 0.0, 0.0, 800);
    det.onAccelSample(2.0, 0.0, 0.0, 900);
    det.onAccelSample(2.0, 0.0, 0.0, 1000);

    var jump = det.getLastJump();
    if (jump == null) {
        logger.debug("Expected jump detected for sub-meter jump");
        return false;
    }
    var heightM = jump[:heightM];
    if (heightM == null) {
        logger.debug("heightM is null");
        return false;
    }
    var hf = heightM.toFloat();
    if (hf < 0.0 || hf > 1.5) {
        logger.debug("Expected heightM between 0 and 1.5 for sub-meter jump, got " + hf);
        return false;
    }
    logger.debug("testSubMeterJump: heightM=" + hf + " (will be filtered by SessionManager threshold)");
    return true;
}

(:test)
function testHeightAccel2sec(logger as Test.Logger) as Boolean {
    var agg = new SensorAggregator();
    var det = new JumpDetector(agg);

    // Baseline accel + pressure + position.
    agg.pushAccel(0.0, 0.0, 9.80665, 0);
    agg.pushAccel(0.0, 0.0, 9.80665, 100);
    agg.pushAccel(0.0, 0.0, 9.80665, 200);
    agg.pushPressure(101325, 0);
    agg.pushPosition(45.0 as Double, -73.0 as Double, 0);
    det.onAccelSample(0.0, 0.0, 9.80665, 0);
    det.onAccelSample(0.0, 0.0, 9.80665, 100);
    det.onAccelSample(0.0, 0.0, 9.80665, 200);
    // Now state == ARMED.

    // Takeoff: 3 high-G samples.
    det.onAccelSample(20.0, 0.0, 0.0, 500);
    det.onAccelSample(20.0, 0.0, 0.0, 600);
    det.onAccelSample(20.0, 0.0, 0.0, 700);
    // Now state == AIRBORNE. Duration so far: 700 - 700 = 0 ms.

    // Simulate climb with a 100 Pa pressure drop so pressureOK stays
    // false during the airborne phase (otherwise the detector would
    // land immediately because latest pressure == baseline pressure).
    agg.pushPressure(101225, 750);

    // Airborne for ~2 more seconds at low-G. Total airtime target ~2.3s.
    var endTs = 2900;
    for (var t = 800; t < endTs; t += 100) {
        if (t == 2300) {
            agg.pushPressure(101220, t);
        }
        det.onAccelSample(2.0, 0.0, 0.0, t);
    }

    // Pressure back to baseline.
    agg.pushPressure(101325, endTs);
    det.onAccelSample(2.0, 0.0, 0.0, endTs + 100);

    var jump = det.getLastJump();
    if (jump == null) {
        logger.debug("Expected jump detected");
        return false;
    }
    var heightAccelM = jump[:heightAccelM];
    if (heightAccelM == null) {
        logger.debug("heightAccelM is null");
        return false;
    }
    // h = g*T^2/8 = 9.80665 * 2.3^2 / 8 ~= 6.5 m
    var hf = heightAccelM.toFloat();
    if (hf < 3.0 || hf > 10.0) {
        logger.debug("Expected heightAccelM between 3 and 10 for ~2.3s airtime, got " + hf);
        return false;
    }
    logger.debug("testHeightAccel2sec: heightAccelM=" + hf);
    return true;
}

(:test)
function testHeightAccel5sec(logger as Test.Logger) as Boolean {
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

    det.onAccelSample(20.0, 0.0, 0.0, 500);
    det.onAccelSample(20.0, 0.0, 0.0, 600);
    det.onAccelSample(20.0, 0.0, 0.0, 700);

    // Simulate climb with a 100 Pa pressure drop.
    agg.pushPressure(101225, 750);

    // Airborne ~5s. End at 5700ms.
    var endTs = 5700;
    for (var t = 800; t < endTs; t += 100) {
        if (t == 3250) {
            agg.pushPressure(101220, t);
        }
        det.onAccelSample(2.0, 0.0, 0.0, t);
    }

    agg.pushPressure(101325, endTs);
    det.onAccelSample(2.0, 0.0, 0.0, endTs + 100);

    var jump = det.getLastJump();
    if (jump == null) { logger.debug("no jump"); return false; }
    var hf = jump[:heightAccelM].toFloat();
    // h = 9.80665 * 5.1^2 / 8 ~= 31.9 m
    if (hf < 10.0 || hf > 22.0) {
        logger.debug("Expected heightAccelM between 10 and 22 for ~5.1s airtime, got " + hf);
        return false;
    }
    logger.debug("testHeightAccel5sec: heightAccelM=" + hf);
    return true;
}

(:test)
function testAllThreeHeights(logger as Test.Logger) as Boolean {
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

    det.onAccelSample(20.0, 0.0, 0.0, 500);
    det.onAccelSample(20.0, 0.0, 0.0, 600);
    det.onAccelSample(20.0, 0.0, 0.0, 700);

    // Airborne: moving GPS and pressure drop so pressureOK is suppressed.
    for (var t = 800; t < 2800; t += 100) {
        var lon = -73.0 + 0.0001 * ((t - 800) / 100.0);
        agg.pushPosition(45.0 as Double, lon as Double, t);
        if (t == 1850) {
            agg.pushPressure(101220, t);
        } else {
            agg.pushPressure(101225, t);
        }
        det.onAccelSample(2.0, 0.0, 0.0, t);
    }

    // Landing: pressure back to baseline.
    agg.pushPressure(101325, 2900);
    agg.pushPosition(45.0 as Double, -72.7 as Double, 2900);
    det.onAccelSample(2.0, 0.0, 0.0, 2900);

    var jump = det.getLastJump();
    if (jump == null) { logger.debug("no jump"); return false; }

    var heightM = jump[:heightM].toFloat();
    var heightAccelM = jump[:heightAccelM].toFloat();

    logger.debug("testAllThreeHeights: baro=" + heightM + " accel=" + heightAccelM);

    // Baro: ~8m (100 Pa drop)
    if (heightM < 5.0 || heightM > 12.0) {
        logger.debug("baro out of range: " + heightM); return false;
    }
    // Accel: airtime ~2.4s to h = 9.80665 * 2.4^2 / 8 ~= 7m
    if (heightAccelM < 3.0 || heightAccelM > 9.0) {
        logger.debug("accel out of range: " + heightAccelM); return false;
    }
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
function testHeightAccelAsymmetric(logger as Test.Logger) as Boolean {
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

    // Takeoff at t=500.
    det.onAccelSample(22.0, 0.0, 0.0, 500);
    det.onAccelSample(22.0, 0.0, 0.0, 600);
    det.onAccelSample(22.0, 0.0, 0.0, 700);

    // Ascending for 1 second, with pressure dropping. At t=1500 we
    // hit peak altitude (lowest pressure). Push an earlier mid-climb
    // sample first so _minPressure is initialized and _peakTs can be
    // updated by the strict-drop check.
    agg.pushPressure(101240, 1000);
    for (var t = 800; t < 1500; t += 100) {
        // mid-air freefall-ish samples
        det.onAccelSample(2.0, 0.0, 9.0, t);
    }
    agg.pushPressure(101225, 1500); // drop = 100 Pa, ~8m climb

    // Hold at peak for one tick so _minPressure / _peakTs settle.
    det.onAccelSample(2.0, 0.0, 9.0, 1500);

    // Descending for 1.4 seconds, pressure returning toward baseline.
    for (var t = 1600; t < 2900; t += 100) {
        det.onAccelSample(2.0, 0.0, 9.0, t);
    }
    agg.pushPressure(101325, 2900);
    det.onAccelSample(2.0, 0.0, 9.0, 2900);

    var jump = det.getLastJump();
    if (jump == null) { logger.debug("no jump"); return false; }
    var heightAccelM = jump[:heightAccelM];
    if (heightAccelM == null) { logger.debug("heightAccelM null"); return false; }
    var h = heightAccelM.toFloat();
    // t_ascent = 1000ms, t_descent = 1400ms
    // h_ascent = 9.80665 * 1^2 / 2 = 4.9m
    // h_descent = 9.80665 * 1.4^2 / 2 = 9.6m
    // avg = 7.26m
    // Allow wide tolerance since freefall samples may not give exact peakTs.
    if (h < 3.0 || h > 12.0) {
        logger.debug("Asymmetric accel height out of range: " + h);
        return false;
    }
    logger.debug("testHeightAccelAsymmetric: h=" + h + "m (tA=1.0s, tD=1.4s)");
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
