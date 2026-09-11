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
// Pressure is pushed to the aggregator at 1 Hz; the detector reads the
// last PRESSURE_LOOKBACK samples and median-of-3 smooths them at
// PENDING completion time.

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

    // Pressure: baseline before takeoff, dip during flight.
    agg.pushPressure(basePa, flightStart - 3000);
    agg.pushPressure(basePa, flightStart - 2000);
    agg.pushPressure(basePa, flightStart - 1000);
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

    agg.pushPosition(45.0 as Double, -73.0 as Double, 500);

    var landingTs = feedValidJump(det, agg, 2000, 1600, 101325, 35);

    // Post-landing pressure back at baseline, then advance past
    // PENDING_MS via tick() (production drives it from pollPressure).
    agg.pushPressure(101325, landingTs + 600);
    agg.pushPressure(101325, landingTs + 1000);
    det.tick(landingTs + 1600);

    var jump = det.getLastJump();
    if (jump == null) {
        logger.debug("testDetectsJump: no jump recorded");
        return false;
    }

    // Airtime is takeoff (window start, first flight sample after the
    // pop) to the landing trigger: 1600 ms of flight + 100 ms spike.
    var durationMs = jump[:durationMs] as Number;
    if (durationMs < 1400 || durationMs > 1900) {
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
    det.tick(landingTs + 1600);

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
    det.tick(landingTs + 1600);

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
    det.tick(landing1 + 1600);

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
    det.tick(landing2 + 1600);

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

// A single-sample splash outlier (-1300 Pa) during flight must be
// killed by the median-of-3 smoothing: the height reflects the real
// ~35 Pa dip, not a 100 m fantasy.
(:test)
function testSplashOutlierKilledByMedian(logger as Test.Logger) as Boolean {
    var agg = new SensorAggregator();
    var det = new JumpDetector(agg);

    var landingTs = feedValidJump(det, agg, 2000, 1600, 101325, 35);

    // Overwrite the flight dip with: real dip samples + one extreme
    // splash sample, then return to baseline.
    agg.pushPressure(99900, landingTs - 200);  // -1425 Pa splash
    agg.pushPressure(101325, landingTs + 600);
    agg.pushPressure(101325, landingTs + 1000);
    det.tick(landingTs + 1600);

    var jump = det.getLastJump();
    if (jump == null) {
        logger.debug("testSplashOutlierKilledByMedian: no jump recorded");
        return false;
    }
    var heightM = jump[:heightM] as Number;
    if (heightM == null || heightM.toFloat() > 5.0) {
        logger.debug("testSplashOutlierKilledByMedian: splash polluted height: " + heightM);
        return false;
    }
    logger.debug("testSplashOutlierKilledByMedian: heightM=" + heightM);
    return true;
}
