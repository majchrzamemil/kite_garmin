// JumpDetectorTests
//
// Unit tests for source/JumpDetector.mc (landing-first redesign).
// Drives the detector through synthetic riding / pop / flight /
// landing-impact sequences using only the public SensorAggregator +
// JumpDetector API. No real sensors or GPS are required, so the tests
// run entirely in the simulator.
//
// Run in the Connect IQ simulator via:
//
//   monkeyc -o build/test.prg -d instinct2 -f monkey.jungle --unit-test
//   monkeydo build/test.prg instinct2 -t
//
// Acceleration profiles are computed so the total-G magnitude matches
// the detector thresholds (accel is passed in m/s^2; total-G =
// sqrt(x^2 + y^2 + z^2) / 9.80665):
//
//   riding chop  z = 16.67 -> 1.70 G  (excursion, above AIRBORNE_G_HIGH)
//   riding calm z =  9.81 -> 1.00 G  (in-band)
//   edge load   z = 17.65 -> 1.80 G  (sustained excursion run)
//   pop         z = 19.61 -> 2.00 G
//   flight      z =  7.35 -> 0.75 G  (quiet + below FREEFALL_SOFT_G)
//   landing     z = 21.57 -> 2.20 G  (above LANDING_SPIKE_G)
//
// Pressure is pushed straight to the aggregator; the detector reads
// the last PRESSURE_LOOKBACK raw samples at PENDING completion time
// (fixtures run at 1 Hz; production polls at 4 Hz with dedup).

import Toybox.Lang;
import Toybox.Test;

// Feed alternating 1.0 G / 1.7 G chop samples (100 ms steps) so the
// backward window scan sees riding noise (cumulative excursions).
function feedChop(det, t0, t1) {
    for (var t = t0; t < t1; t += 100) {
        var z = ((t / 100) % 2 == 0) ? 9.81 : 16.67;
        det.onAccelSample(0.0, 0.0, z, t);
    }
}

// Feed quiet flight samples at 0.75 G.
function feedFlight(det, t0, t1) {
    for (var t = t0; t < t1; t += 100) {
        det.onAccelSample(0.0, 0.0, 7.35, t);
    }
}

// The accelerometer half of a valid jump: edge load -> pop -> quiet
// flight -> landing impact, with no pressure pushed. Lets a test supply
// its own pressure series (e.g. a replay of real sensor data) while
// still driving the detector through to PENDING.
// Returns the landing impact timestamp (ms).
function feedValidJumpAccelOnly(det, tEdge, airtimeMs) {
    feedChop(det, tEdge - 1500, tEdge);
    for (var t = tEdge; t < tEdge + 600; t += 100) {
        det.onAccelSample(0.0, 0.0, 17.65, t);
    }
    for (var t = tEdge + 600; t < tEdge + 900; t += 100) {
        det.onAccelSample(0.0, 0.0, 19.61, t);
    }
    var flightStart = tEdge + 900;
    var landingTs = flightStart + airtimeMs;
    feedFlight(det, flightStart, landingTs);
    det.onAccelSample(0.0, 0.0, 21.57, landingTs);
    det.onAccelSample(0.0, 0.0, 21.57, landingTs + 100);
    return landingTs + 100;
}

// Full valid jump: edge load -> pop -> quiet flight -> landing impact.
// Returns the landing impact timestamp (ms).
function feedValidJump(det, agg, tEdge, airtimeMs, basePa, dipPa) {
    // Riding chop before the edge.
    feedChop(det, tEdge - 1500, tEdge);

    // Sustained edge load (6 x 1.8 G -> run > EXCURSION_RUN_MAX so the
    // backward scan stops here on the real landing analysis).
    for (var t = tEdge; t < tEdge + 600; t += 100) {
        det.onAccelSample(0.0, 0.0, 17.65, t);
    }

    // Pop (3 x 2.0 G). This itself triggers a landing-spike analysis
    // which must discard (chop behind it, no reduced-G sample).
    for (var t = tEdge + 600; t < tEdge + 900; t += 100) {
        det.onAccelSample(0.0, 0.0, 19.61, t);
    }

    var flightStart = tEdge + 900;
    var landingTs = flightStart + airtimeMs;

    // Quiet flight with freefall evidence.
    feedFlight(det, flightStart, landingTs);

    // Pressure: baseline before takeoff, gradual dip during flight
    // (an early 12 Pa sample >= DIP_START_PA anchors the takeoff
    // refinement, then the full dip).
    agg.pushPressure(basePa, flightStart - 3000);
    agg.pushPressure(basePa, flightStart - 2000);
    agg.pushPressure(basePa, flightStart - 1000);
    agg.pushPressure(basePa - 12, flightStart + 200);
    agg.pushPressure(basePa - dipPa, flightStart + airtimeMs / 2);
    if (airtimeMs >= 1000) {
        agg.pushPressure(basePa - dipPa, flightStart + airtimeMs - 300);
    }

    // Landing impact: 2 x 2.2 G.
    det.onAccelSample(0.0, 0.0, 21.57, landingTs);
    det.onAccelSample(0.0, 0.0, 21.57, landingTs + 100);

    return landingTs + 100;
}

// A complete, valid jump: edge load, pop, quiet flight with freefall
// evidence, landing impact, and a 35 Pa dip that returns to baseline.
// The detector must record it.
(:test)
function testDetectsJump(logger as Test.Logger) as Boolean {
    var agg = new SensorAggregator();
    var det = new JumpDetector(agg);

    agg.pushPosition(45.0 as Double, -73.0 as Double, 500, -1.0f);

    var landingTs = feedValidJump(det, agg, 2000, 1600, 101325, 35);

    // Post-landing pressure back at baseline, then advance past
    // PENDING_MS via tick() (production drives it from pollPressure).
    agg.pushPressure(101325, landingTs + 600);
    agg.pushPressure(101325, landingTs + 1000);
    agg.pushPressure(101325, landingTs + 2000);
    agg.pushPressure(101325, landingTs + 2900);
    det.tick(landingTs + 3200);

    var jump = det.getLastJump();
    if (jump == null) {
        logger.debug("testDetectsJump: no jump recorded");
        return false;
    }

    // Airtime is the refined takeoff (dip start ~200 ms into the
    // 1600 ms flight) to the landing trigger: ~1500 ms.
    var durationMs = jump[:durationMs] as Number;
    if (durationMs < 1300 || durationMs > 1900) {
        logger.debug("testDetectsJump: unexpected durationMs=" + durationMs);
        return false;
    }

    // 35 Pa dip ~= 2.9 m via ICAO.
    var heightM = jump[:heightM] as Number;
    if (heightM == null || heightM.toFloat() < 2.0 || heightM.toFloat() > 4.0) {
        logger.debug("testDetectsJump: unexpected heightM=" + heightM);
        return false;
    }

    var peakDelta = jump[:peakDeltaPa] as Number;
    if (peakDelta == null || peakDelta < 25 || peakDelta > 45) {
        logger.debug("testDetectsJump: unexpected peakDeltaPa=" + peakDelta);
        return false;
    }

    var lpc = jump.get(:landingPathCode);
    if (lpc == null || !lpc.equals(0)) {
        logger.debug("testDetectsJump: expected landingPathCode=0, got " + lpc);
        return false;
    }

    logger.debug("testDetectsJump: durationMs=" + durationMs
        + " heightM=" + heightM + " peakDeltaPa=" + peakDelta);
    return true;
}

// The pop itself fires the landing-spike trigger; the backward window
// is riding chop with no reduced-G sample, so it must be discarded and
// the detector re-armed in time for the real landing.
// (Exercised implicitly by feedValidJump; this test makes the
// no-jump side explicit when there is no real landing afterwards.)
(:test)
function testPopSpikeDoesNotRecord(logger as Test.Logger) as Boolean {
    var agg = new SensorAggregator();
    var det = new JumpDetector(agg);

    feedChop(det, 0, 2000);

    // Pop with no flight and no landing behind it.
    det.onAccelSample(0.0, 0.0, 19.61, 2000);
    det.onAccelSample(0.0, 0.0, 19.61, 2100);

    // Continue riding chop well past any PENDING/coast window.
    feedChop(det, 2200, 6000);
    agg.pushPressure(101325, 3000);
    agg.pushPressure(101325, 4000);
    agg.pushPressure(101325, 5000);
    det.tick(6000);

    var jump = det.getLastJump();
    if (jump != null) {
        logger.debug("testPopSpikeDoesNotRecord: unexpected jump: " + jump);
        return false;
    }
    logger.debug("testPopSpikeDoesNotRecord: pop discarded, no jump");
    return true;
}

// A landing impact with less than MIN_FLIGHT_MS of quiet window behind
// it is a chop slap, not a jump.
(:test)
function testSubSecondHopDiscarded(logger as Test.Logger) as Boolean {
    var agg = new SensorAggregator();
    var det = new JumpDetector(agg);

    // Edge load + pop + only 500 ms of quiet flight, then a landing
    // impact: the backward window is bounded by the edge-load run, so
    // the flight window really is sub-second.
    feedValidJump(det, agg, 2000, 500, 101325, 35);

    // Post-landing pressure back at baseline.
    var landingTs = 2000 + 900 + 500 + 100; // tEdge + pop + airtime + spike
    agg.pushPressure(101325, landingTs + 600);
    agg.pushPressure(101325, landingTs + 1000);
    agg.pushPressure(101325, landingTs + 2000);
    agg.pushPressure(101325, landingTs + 2900);
    det.tick(landingTs + 3200);

    var jump = det.getLastJump();
    if (jump != null) {
        logger.debug("testSubSecondHopDiscarded: unexpected jump: " + jump);
        return false;
    }
    logger.debug("testSubSecondHopDiscarded: sub-second hop discarded");
    return true;
}

// A quiet window without any reduced-G sample (flight always >= 0.9 G)
// is calm flat-water riding, not a jump.
(:test)
function testNoReducedGDiscarded(logger as Test.Logger) as Boolean {
    var agg = new SensorAggregator();
    var det = new JumpDetector(agg);

    feedChop(det, 0, 2000);

    // Two seconds of calm 1.0 G (in-band but never below 0.9 G).
    for (var t = 2000; t < 4000; t += 100) {
        det.onAccelSample(0.0, 0.0, 9.81, t);
    }

    // Landing impact.
    det.onAccelSample(0.0, 0.0, 21.57, 4000);
    det.onAccelSample(0.0, 0.0, 21.57, 4100);

    agg.pushPressure(101325, 1000);
    agg.pushPressure(101325, 1500);
    agg.pushPressure(101290, 3000);
    agg.pushPressure(101325, 4700);
    agg.pushPressure(101325, 5300);
    det.tick(5700);

    var jump = det.getLastJump();
    if (jump != null) {
        logger.debug("testNoReducedGDiscarded: unexpected jump: " + jump);
        return false;
    }
    logger.debug("testNoReducedGDiscarded: no reduced-G evidence, discarded");
    return true;
}

// Riding chop with occasional slaps and flat pressure must never
// produce a jump: every spike analysis dies on the chop window or the
// missing reduced-G evidence.
(:test)
function testRidingChopNoJump(logger as Test.Logger) as Boolean {
    var agg = new SensorAggregator();
    var det = new JumpDetector(agg);

    var t = 0;
    while (t < 20000) {
        // Alternating chop.
        var z = ((t / 100) % 2 == 0) ? 9.81 : 16.67;
        det.onAccelSample(0.0, 0.0, z, t);
        // A chop slap (2 x 1.9 G) every 4 s.
        if (t % 4000 == 3900) {
            det.onAccelSample(0.0, 0.0, 18.63, t + 100);
            det.onAccelSample(0.0, 0.0, 18.63, t + 200);
            t += 200;
        }
        t += 100;
    }

    // Flat pressure throughout.
    for (var p = 0; p < 20; p++) {
        agg.pushPressure(101325, p * 1000);
    }
    det.tick(21000);

    var jump = det.getLastJump();
    if (jump != null) {
        logger.debug("testRidingChopNoJump: unexpected jump: " + jump);
        return false;
    }
    logger.debug("testRidingChopNoJump: chop session produced no jumps");
    return true;
}

// Tack regression (2026-09-10 session, 07:18): speed bleeds off
// through a turn, the ram-air pressure change looks like an ~80 Pa
// climb, and the pressure NEVER returns to the pre-tack baseline.
// The dip passes but the return check must discard the candidate.
(:test)
function testTackDriftRejected(logger as Test.Logger) as Boolean {
    var agg = new SensorAggregator();
    var det = new JumpDetector(agg);

    var landingTs = feedValidJump(det, agg, 2000, 1600, 101325, 80);

    // Post-"landing" pressure stays 80 Pa below baseline (the tack
    // drift persists - the rider is now on the new tack).
    agg.pushPressure(101245, landingTs + 600);
    agg.pushPressure(101245, landingTs + 1000);
    agg.pushPressure(101245, landingTs + 2000);
    agg.pushPressure(101245, landingTs + 2900);
    det.tick(landingTs + 3200);

    var jump = det.getLastJump();
    if (jump != null) {
        logger.debug("testTackDriftRejected: tack drift recorded a jump: " + jump);
        return false;
    }
    logger.debug("testTackDriftRejected: drift without return discarded");
    return true;
}

// Water-on-port chaos regression (2026-09-10 session, 07:13): the
// pressure port gets dunked, pressure swings by hundreds of Pa over a
// few seconds and settles on a new offset. Replayed pressure series
// reconstructed from the FIT altitude log (alt -> Pa at ~12 Pa/m).
// With riding chop + slaps + calm stretches (including sub-0.9 G
// crests) no jump may be recorded.
(:test)
function testWaterChaosReplayNoJump(logger as Test.Logger) as Boolean {
    var agg = new SensorAggregator();
    var det = new JumpDetector(agg);

    // Reconstructed pressure (Pa) at 1 Hz-ish cadence, t in seconds.
    var pa = [
        101325, 101363, 101836, 102376, 102542,            // port dunk
        102472, 101848, 101555, 101387,                    // recovery
        101299, 101275, 101248, 101210, 101195,            // settling
        101217, 101222, 101222, 101222,                    // settled low
        101383, 101426                                      // tack drift low
    ];
    var paT = [
        0, 1, 2, 3, 4, 7, 8, 9, 10, 11, 12, 13, 14, 15, 16, 17, 18, 19, 20, 21
    ];
    for (var i = 0; i < pa.size(); i++) {
        agg.pushPressure(pa[i], paT[i] * 1000);
    }

    // Accel: chop with a calm stretch (0.85 G crests) before each of
    // three slaps (t=10 s mid-recovery, t=16 s on the settle, t=21 s
    // on the drift).
    feedChop(det, 0, 8000);
    det.onAccelSample(0.0, 0.0, 21.57, 8000);
    det.onAccelSample(0.0, 0.0, 21.57, 8100);

    feedChop(det, 8200, 12000);
    det.onAccelSample(0.0, 0.0, 21.57, 12000);
    det.onAccelSample(0.0, 0.0, 21.57, 12100);

    // Calm stretch with sub-0.9 G samples before the t=16 s slap.
    for (var t = 12200; t < 16000; t += 100) {
        det.onAccelSample(0.0, 0.0, 8.34, t);
    }
    det.onAccelSample(0.0, 0.0, 21.57, 16000);
    det.onAccelSample(0.0, 0.0, 21.57, 16100);

    // Calm stretch before the t=21 s slap.
    for (var t2 = 16200; t2 < 21000; t2 += 100) {
        det.onAccelSample(0.0, 0.0, 8.34, t2);
    }
    det.onAccelSample(0.0, 0.0, 21.57, 21000);
    det.onAccelSample(0.0, 0.0, 21.57, 21100);

    // Let every PENDING window complete.
    det.tick(23000);

    var jump = det.getLastJump();
    if (jump != null) {
        logger.debug("testWaterChaosReplayNoJump: chaos recorded a jump: " + jump);
        return false;
    }
    logger.debug("testWaterChaosReplayNoJump: water chaos produced no jumps");
    return true;
}

// Two consecutive jumps: both must be recorded, the second starting
// after the first ends, with no crash in between.
(:test)
function testTwoConsecutiveJumps(logger as Test.Logger) as Boolean {
    var agg = new SensorAggregator();
    var det = new JumpDetector(agg);

    // Jump 1.
    var landing1 = feedValidJump(det, agg, 2000, 1600, 101325, 35);
    agg.pushPressure(101325, landing1 + 600);
    agg.pushPressure(101325, landing1 + 1000);
    det.tick(landing1 + 3200);

    var jump1 = det.getLastJump();
    if (jump1 == null) {
        logger.debug("testTwoConsecutiveJumps: jump1 not recorded");
        return false;
    }

    // Ride out the COAST_MS debounce with chop.
    feedChop(det, landing1 + 1700, landing1 + 3400);

    // Jump 2 (after the coast window).
    var landing2 = feedValidJump(det, agg, landing1 + 3500, 1500, 101325, 40);
    agg.pushPressure(101325, landing2 + 600);
    agg.pushPressure(101325, landing2 + 1000);
    det.tick(landing2 + 3200);

    var jump2 = det.getLastJump();
    if (jump2 == null) {
        logger.debug("testTwoConsecutiveJumps: jump2 not recorded");
        return false;
    }
    var j1End = jump1.get(:endTs) as Number;
    var j2Start = jump2.get(:startTs) as Number;
    if (j2Start <= j1End) {
        logger.debug("testTwoConsecutiveJumps: jump2 overlaps jump1 ("
            + j2Start + " <= " + j1End + ")");
        return false;
    }
    var height2 = jump2[:heightM] as Number;
    if (height2 == null || height2.toFloat() < 2.0 || height2.toFloat() > 5.0) {
        logger.debug("testTwoConsecutiveJumps: unexpected jump2 heightM=" + height2);
        return false;
    }
    logger.debug("testTwoConsecutiveJumps: both jumps recorded, no crash");
    return true;
}

// A single-sample splash outlier (-1425 Pa) during flight must not set
// the height: the second-lowest flight sample is used, so the result
// reflects the real ~35 Pa dip, not a 100 m fantasy.
(:test)
function testSplashOutlierRejected(logger as Test.Logger) as Boolean {
    var agg = new SensorAggregator();
    var det = new JumpDetector(agg);

    var landingTs = feedValidJump(det, agg, 2000, 1600, 101325, 35);

    // Overwrite the flight dip with: real dip samples + one extreme
    // splash sample, then return to baseline.
    agg.pushPressure(99900, landingTs - 200);  // -1425 Pa splash
    agg.pushPressure(101325, landingTs + 600);
    agg.pushPressure(101325, landingTs + 1000);
    agg.pushPressure(101325, landingTs + 2000);
    agg.pushPressure(101325, landingTs + 2900);
    det.tick(landingTs + 3200);

    var jump = det.getLastJump();
    if (jump == null) {
        logger.debug("testSplashOutlierRejected: no jump recorded");
        return false;
    }
    var heightM = jump[:heightM] as Number;
    if (heightM == null || heightM.toFloat() > 5.0) {
        logger.debug("testSplashOutlierRejected: splash polluted height: " + heightM);
        return false;
    }
    logger.debug("testSplashOutlierRejected: heightM=" + heightM);
    return true;
}

// Stationary rider regression (2026-09-11 session, jumps 1-2): a
// rider standing/wading in the water gets kite-yank wrist spikes and
// port-dunk pressure dips that pass every accelerometer/baro gate.
// The GPS speed gate must reject them: two identical fixes before
// takeoff = 0 m/s.
(:test)
function testStationaryRiderRejected(logger as Test.Logger) as Boolean {
    var agg = new SensorAggregator();
    var det = new JumpDetector(agg);

    var landingTs = feedValidJump(det, agg, 2000, 1600, 101325, 35);

    // Post-landing pressure back at baseline.
    agg.pushPressure(101325, landingTs + 600);
    agg.pushPressure(101325, landingTs + 1000);
    agg.pushPressure(101325, landingTs + 2000);
    agg.pushPressure(101325, landingTs + 2900);

    // Two identical GPS fixes (rider stationary) before takeoff.
    agg.pushPosition(45.0 as Double, -73.0 as Double, 3000, -1.0f);
    agg.pushPosition(45.0 as Double, -73.0 as Double, 3500, -1.0f);

    det.tick(landingTs + 3200);

    var jump = det.getLastJump();
    if (jump != null) {
        logger.debug("testStationaryRiderRejected: stationary fake recorded: " + jump);
        return false;
    }
    logger.debug("testStationaryRiderRejected: stationary rider rejected");
    return true;
}

// Jump length regression (2026-09-11 session: lengthM=0.00 on every
// jump because positions were stamped with the GPS epoch clock while
// the detector compares System.getTimer() milliseconds). With the
// clocks aligned, the takeoff position (last fix at/before takeoff)
// and the landing position must produce a positive length.
(:test)
function testJumpLengthRecorded(logger as Test.Logger) as Boolean {
    var agg = new SensorAggregator();
    var det = new JumpDetector(agg);

    var landingTs = feedValidJump(det, agg, 2000, 1600, 101325, 35);

    // Post-landing pressure back at baseline.
    agg.pushPressure(101325, landingTs + 600);
    agg.pushPressure(101325, landingTs + 1000);
    agg.pushPressure(101325, landingTs + 2000);
    agg.pushPressure(101325, landingTs + 2900);

    // Moving rider: two pre-takeoff fixes ~4 m/s apart, then a landing
    // fix ~23 m downwind.
    agg.pushPosition(45.0 as Double, -73.0 as Double, 2000, -1.0f);
    agg.pushPosition(45.00003 as Double, -73.00003 as Double, 3100, -1.0f);
    agg.pushPosition(45.0002 as Double, -73.0002 as Double, landingTs + 400, -1.0f);

    det.tick(landingTs + 3200);

    var jump = det.getLastJump();
    if (jump == null) {
        logger.debug("testJumpLengthRecorded: no jump recorded");
        return false;
    }
    var lengthM = jump[:lengthM] as Number;
    if (lengthM == null || lengthM.toFloat() <= 0.0) {
        logger.debug("testJumpLengthRecorded: lengthM not recorded: " + lengthM);
        return false;
    }
    logger.debug("testJumpLengthRecorded: lengthM=" + lengthM);
    return true;
}

// Accelerometer batch timestamps (2026-09-14 regression): the streaming
// listener delivers one second of samples per callback. Stamping them
// all with the arrival instant would collapse every window the detector
// walks backwards through, so the batch is spread backwards at the
// sample interval.
(:test)
function testBatchSampleTimeMonotone(logger as Test.Logger) as Boolean {
    var n = 25;
    var rate = 25;
    var now = 100000;

    var prev = -1;
    for (var i = 0; i < n; i++) {
        var t = batchSampleTime(now, n, i, rate);
        if (t <= prev) {
            logger.debug("testBatchSampleTimeMonotone: not increasing at i=" + i
                + " t=" + t + " prev=" + prev);
            return false;
        }
        prev = t;
    }

    if (batchSampleTime(now, n, n - 1, rate) != now) {
        logger.debug("testBatchSampleTimeMonotone: last sample not at now");
        return false;
    }
    if (batchSampleTime(now, n, 0, rate) != now - 960) {
        logger.debug("testBatchSampleTimeMonotone: first sample at "
            + batchSampleTime(now, n, 0, rate) + " expected " + (now - 960));
        return false;
    }
    // A single-sample batch must land exactly on the arrival instant.
    if (batchSampleTime(now, 1, 0, rate) != now) {
        logger.debug("testBatchSampleTimeMonotone: single-sample batch misplaced");
        return false;
    }
    return true;
}

// ---------------------------------------------------------------------
// Replays of real sensor data
//
// The series below are not synthetic. They were read out of
// GARMIN/ACTIVITY/2026-09-14-14-15-52.fit - a 44-minute kitesurf
// session on the Instinct Solar 2 - by converting the recorded
// barometric altitude back to pressure with the inverse ICAO formula
// (P = 101325 * (1 - h/44330) ^ (1/0.190263)). Sample spacing in that
// file is nominally 1 Hz.
// ---------------------------------------------------------------------

// Push a real 1 Hz pressure series starting at t0.
function feedRealPressure(agg, t0, paSeries) {
    for (var i = 0; i < paSeries.size(); i++) {
        agg.pushPressure(paSeries[i], t0 + i * 1000);
    }
}

// Water over the pressure port, t=1167 s of the real session. The
// signature is violent and unmistakable: one sample +800 Pa, the next
// -1384 Pa, then a slow exponential decay that is still 66 Pa off
// baseline fourteen seconds later.
//
// This is the single biggest false-positive source in the sport - it
// dwarfs any real jump - and it is what the dip-AND-RETURN requirement
// exists for. The dip gate alone passes it happily.
(:test)
function testRealPortDunkRejected(logger as Test.Logger) as Boolean {
    var agg = new SensorAggregator();
    var det = new JumpDetector(agg);

    // Samples land at -100, 900, 1900 (baseline), 2900, 3900 (flight),
    // then 4900 onwards (post-landing) for a jump landing at 4600.
    feedRealPressure(agg, -100, [
        99892, 99894, 99896,          // clean riding baseline
        100692,                       // port goes under: +800 Pa
        98508,                        // and plunges: -1384 Pa
        99070, 99406, 99553, 99645,   // slow decay, never reaches baseline
        99702, 99718, 99740, 99761
    ]);

    var landingTs = feedValidJumpAccelOnly(det, 2000, 1600);
    det.tick(landingTs + 3200);

    var jump = det.getLastJump();
    if (jump != null) {
        logger.debug("testRealPortDunkRejected: wet port recorded as jump: " + jump);
        return false;
    }
    logger.debug("testRealPortDunkRejected: wet-port decay rejected");
    return true;
}

// The second dunk of the same session, t=1477 s. Same shape, different
// magnitudes - included because one replay could be a fluke.
(:test)
function testRealPortDunk2Rejected(logger as Test.Logger) as Boolean {
    var agg = new SensorAggregator();
    var det = new JumpDetector(agg);

    feedRealPressure(agg, -100, [
        99932, 99939, 99934,
        100745,                       // +813 Pa
        98672,                        // -1260 Pa
        99254, 99505, 99640, 99730,
        99761, 99792, 99813, 99825
    ]);

    var landingTs = feedValidJumpAccelOnly(det, 2000, 1600);
    det.tick(landingTs + 3200);

    var jump = det.getLastJump();
    if (jump != null) {
        logger.debug("testRealPortDunk2Rejected: wet port recorded as jump: " + jump);
        return false;
    }
    logger.debug("testRealPortDunk2Rejected: second wet-port decay rejected");
    return true;
}

// The quietest 25-sample stretch of the real session (t=2382-2421 s,
// riding at 4.5-5.6 m/s). Even here the barometer wanders over a 31 Pa
// range - against a BARO_DIP_PA of 18. A full accelerometer jump
// signature laid over this noise must still fail the dip gate, because
// the noise never produces a sustained excursion.
(:test)
function testRealQuietRidingNoFalseJump(logger as Test.Logger) as Boolean {
    var agg = new SensorAggregator();
    var det = new JumpDetector(agg);

    feedRealPressure(agg, -100, [
        99958, 99961, 99956, 99949, 99946, 99956, 99965, 99965,
        99968, 99956, 99946, 99949, 99949, 99942, 99942, 99937
    ]);

    var landingTs = feedValidJumpAccelOnly(det, 2000, 1600);
    det.tick(landingTs + 3200);

    var jump = det.getLastJump();
    if (jump != null) {
        logger.debug("testRealQuietRidingNoFalseJump: noise recorded as jump: " + jump);
        return false;
    }
    logger.debug("testRealQuietRidingNoFalseJump: riding baro noise rejected");
    return true;
}

// Bad-read immunity, using the real magnitudes from both sources: a
// genuine 35 Pa jump dip sitting on the real quiet-riding baseline,
// with one corrupt sample of the measured wet-port size (-1384 Pa)
// dropped into the middle of the flight.
//
// The median-of-3 smoothing this replaced would also have survived
// this, but at the cost of erasing any dip shorter than three samples.
// Taking the second-lowest flight sample keeps the bad-read protection
// without that cost - which is the whole point of the change.
(:test)
function testRealDipSurvivesBadRead(logger as Test.Logger) as Boolean {
    var agg = new SensorAggregator();
    var det = new JumpDetector(agg);

    // Real quiet-riding baseline.
    agg.pushPressure(99958, -100);
    agg.pushPressure(99961, 900);
    agg.pushPressure(99956, 1900);

    // Flight: real dip, one corrupt sample, real dip again.
    agg.pushPressure(99923, 3200);   // -35 Pa, a genuine ~3 m jump
    agg.pushPressure(98574, 3700);   // corrupt: -1384 Pa, port dunked
    agg.pushPressure(99923, 4200);   // -35 Pa again

    // Back to baseline after landing.
    agg.pushPressure(99958, 5000);
    agg.pushPressure(99958, 5600);
    agg.pushPressure(99958, 6200);

    var landingTs = feedValidJumpAccelOnly(det, 2000, 1600);
    det.tick(landingTs + 3200);

    var jump = det.getLastJump();
    if (jump == null) {
        logger.debug("testRealDipSurvivesBadRead: real dip not recorded");
        return false;
    }
    var heightM = jump[:heightM] as Number;
    if (heightM == null || heightM.toFloat() < 1.5 || heightM.toFloat() > 5.0) {
        logger.debug("testRealDipSurvivesBadRead: height came from the bad read: " + heightM);
        return false;
    }
    logger.debug("testRealDipSurvivesBadRead: heightM=" + heightM + " (bad read ignored)");
    return true;
}

// A short jump must still produce a length. At 1 Hz the takeoff and
// landing anchors can fall nearest the SAME fix, which would report
// 0 m for a real jump; the bracketing fallback (last fix at or before
// takeoff, first at or after landing) covers that case.
//
// Pressure here is an explicit 4 Hz dip rather than the feedValidJump
// fixture: a 900 ms flight only holds two samples at 1 Hz, and one of
// them is the shallow dip-start marker, so the second-lowest rule
// correctly refuses to confirm it.
(:test)
function testShortJumpStillHasLength(logger as Test.Logger) as Boolean {
    var agg = new SensorAggregator();
    var det = new JumpDetector(agg);

    // 1 Hz fixes, rider tracking at roughly 7 m/s.
    agg.pushPosition(45.0 as Double,      -73.0 as Double,      2000, 7.0f);
    agg.pushPosition(45.00006 as Double,  -73.00006 as Double,  3000, 7.0f);
    agg.pushPosition(45.00012 as Double,  -73.00012 as Double,  4000, 7.0f);
    agg.pushPosition(45.00018 as Double,  -73.00018 as Double,  5000, 7.0f);
    agg.pushPosition(45.00024 as Double,  -73.00024 as Double,  6000, 7.0f);
    agg.pushPosition(45.00030 as Double,  -73.00030 as Double,  7000, 7.0f);

    // Baseline, then a 4 Hz dip through the 900 ms flight, then return.
    agg.pushPressure(101325, -100);
    agg.pushPressure(101325, 900);
    agg.pushPressure(101325, 1900);
    agg.pushPressure(101290, 3100);
    agg.pushPressure(101290, 3350);
    agg.pushPressure(101290, 3600);
    agg.pushPressure(101290, 3850);
    agg.pushPressure(101325, 4400);
    agg.pushPressure(101325, 5000);
    agg.pushPressure(101325, 5600);

    var landingTs = feedValidJumpAccelOnly(det, 2000, 900);
    det.tick(landingTs + 3200);

    var jump = det.getLastJump();
    if (jump == null) {
        logger.debug("testShortJumpStillHasLength: short jump not recorded");
        return false;
    }
    var lengthM = jump[:lengthM] as Float;
    if (lengthM == null || lengthM <= 0.0) {
        logger.debug("testShortJumpStillHasLength: length collapsed to " + lengthM);
        return false;
    }
    if (lengthM > 30.0) {
        logger.debug("testShortJumpStillHasLength: length overstated " + lengthM);
        return false;
    }
    logger.debug("testShortJumpStillHasLength: lengthM=" + lengthM);
    return true;
}

// Jump length must not absorb the PENDING wait. _recordJump runs
// PENDING_MS after the landing impact, and the old code measured to
// getLatestPosition() - so fixes that keep arriving while the
// candidate waits used to inflate every length by seconds of riding.
(:test)
function testLengthExcludesPendingLatency(logger as Test.Logger) as Boolean {
    var agg = new SensorAggregator();
    var det = new JumpDetector(agg);

    // Fixes through takeoff and landing...
    agg.pushPosition(45.0 as Double,      -73.0 as Double,      2000, 8.0f);
    agg.pushPosition(45.00007 as Double,  -73.00007 as Double,  3000, 8.0f);
    agg.pushPosition(45.00014 as Double,  -73.00014 as Double,  4000, 8.0f);

    var landingTs = feedValidJump(det, agg, 2000, 1600, 101325, 35);
    agg.pushPressure(101325, landingTs + 600);
    agg.pushPressure(101325, landingTs + 1000);
    agg.pushPressure(101325, landingTs + 2000);
    agg.pushPressure(101325, landingTs + 2900);

    // ...and three more seconds of riding while PENDING runs. None of
    // this travel belongs to the jump.
    agg.pushPosition(45.00050 as Double, -73.00050 as Double, landingTs + 1000, 8.0f);
    agg.pushPosition(45.00090 as Double, -73.00090 as Double, landingTs + 2000, 8.0f);
    agg.pushPosition(45.00140 as Double, -73.00140 as Double, landingTs + 3000, 8.0f);

    det.tick(landingTs + 3200);

    var jump = det.getLastJump();
    if (jump == null) {
        logger.debug("testLengthExcludesPendingLatency: no jump recorded");
        return false;
    }
    var lengthM = jump[:lengthM] as Float;
    // The far fix is ~180 m from takeoff; a 1.6 s jump is nowhere near.
    if (lengthM == null || lengthM > 40.0) {
        logger.debug("testLengthExcludesPendingLatency: pending latency inflated length to " + lengthM);
        return false;
    }
    logger.debug("testLengthExcludesPendingLatency: lengthM=" + lengthM);
    return true;
}
