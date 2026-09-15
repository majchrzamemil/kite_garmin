// JumpDetector
//
// Landing-first jump detection for kiteboarding on a wrist-worn
// accelerometer + barometer.
//
// DESIGN (2026-09 redesign)
//
// The previous takeoff-first design (1.10 G takeoff spike -> airborne
// -> landing paths) produced 23 fake jumps in one real session: the
// 1.10 G threshold sits inside riding-chop noise, and the 20 Pa
// barometric "climb" gate is satisfied ~38% of all seconds by ram-air
// pressure changes through tacks and water film on the pressure port.
//
// The new design inverts the state machine: we trigger on the LANDING
// IMPACT (the single biggest, rarest, cleanest wrist signal in
// kiteboarding) and validate by looking BACKWARDS at the window before
// the impact:
//
//   1. TRIGGER   - total-G >= LANDING_SPIKE_G for LANDING_SPIKE_SAMPLES
//                  consecutive samples (~80 ms at 25 Hz).
//   2. WINDOW    - walk back through the pre-impact accelerometer
//                  history: an airborne wrist is QUIET (chop noise
//                  stops). The window ends at "sustained riding"
//                  (a run of high-G samples, or too many cumulative
//                  high-G excursion samples = chop/edging).
//   3. TAKEOFF   - anchored at the first high-G excursion inside the
//                  window (the pop) when present, else at the window
//                  start.
//   4. REDUCED-G - at least one sample below FREEFALL_SOFT_G inside
//                  the flight (weightlessness evidence).
//   5. PENDING   - the candidate is held for PENDING_MS after landing
//                  so post-landing barometer samples arrive.
//   6. BARO      - median-of-3 smoothed pressure must show a
//                  dip-then-RETURN shape: >= BARO_DIP_PA below the
//                  pre-takeoff baseline during flight, and back within
//                  BARO_RETURN_PA of the baseline after landing. A bare
//                  "dropped 20 Pa sometime in 20 s" no longer exists —
//                  the return check is what rejects tack ram-air drift.
//   7. RECORD    - height from the ICAO formula on the smoothed dip.
//
// There is no AIRBORNE watchdog any more: a candidate that fails any
// gate is discarded (short cooldown), never force-landed into the FIT
// file. The GPS-speed landing path is gone too — real kite jumps land
// at riding speed (5-8 m/s), so that path could only ever close fake
// events.
//
// States
//   IDLE     - waiting for the internal G ring to warm up.
//   ARMED    - watching for a landing impact spike.
//   PENDING  - candidate accepted on accelerometer evidence; waiting
//              for the post-landing barometer confirmation window.
//   COASTING - post-event debounce (COAST_MS after a recorded jump,
//              DISCARD_COAST_MS after a discarded event).
//
// Accelerometer unit note: App.pollAccel() converts Sensor.getInfo()
// .accel milli-g values to m/s^2 before calling onAccelSample()
// (verified against the Connect IQ docs: accel is in millig-units).

import Toybox.Lang;
import Toybox.Math;

class JumpDetector {

    static const STATE_IDLE     = 0;
    static const STATE_ARMED    = 1;
    static const STATE_PENDING  = 2;
    static const STATE_COASTING = 4;

    // --- Landing impact trigger ---------------------------------------
    // A kiteboard landing yanks the wrist well above riding noise.
    // Sustained for LANDING_SPIKE_SAMPLES so a single chop slap does
    // not fire on its own.
    static const LANDING_SPIKE_G       = 1.8;
    static const LANDING_SPIKE_SAMPLES = 2;

    // --- Backward airborne-window scan --------------------------------
    // Above AIRBORNE_G_HIGH a sample is an "excursion": riding chop,
    // edging load, kite yanks, the takeoff pop. A contiguous run
    // longer than EXCURSION_RUN_MAX, or more than MAX_WINDOW_EXCURSIONS
    // cumulative excursion samples, means we have walked back into
    // riding and the window stops there.
    static const AIRBORNE_G_HIGH       = 1.5;
    static const EXCURSION_RUN_MAX    = 5;
    static const MAX_WINDOW_EXCURSIONS = 8;

    // Flight duration bounds for a candidate window.
    static const MIN_FLIGHT_MS         = 800;
    static const MAX_FLIGHT_MS         = 8000;

    // At least one sample below this inside the flight = weightlessness
    // evidence (kite-line tension keeps G near 1, but the apex of even
    // a small jump dips below 0.9 G for a few samples at 25 Hz).
    static const FREEFALL_SOFT_G       = 0.90;

    // GPS speed gate: real jumps only happen from riding speed. A
    // stationary rider (wading out, body-dragging, water-start
    // attempts) produces kite-yank spikes and port-dunk dips that
    // otherwise pass every accelerometer/baro gate.
    static const TAKEOFF_SPEED_MPS      = 3.0;

    // --- Barometric confirmation -------------------------------------
    // Applied at PENDING completion to the median-of-3 smoothed 1 Hz
    // pressure series. dip >= BARO_DIP_PA during flight AND the last
    // post-landing sample within BARO_RETURN_PA of the pre-takeoff
    // baseline. The return check is what rejects tack ram-air drift.
    static const BARO_DIP_PA           = 18;
    static const BARO_RETURN_PA        = 30;
    static const BASELINE_BACK_MS      = 4000;
    static const BASELINE_GAP_MS       = 500;
    static const PENDING_MS            = 1500;
    static const PRESSURE_LOOKBACK     = 20;

    // Takeoff refinement: the first smoothed flight sample at least
    // this far below the baseline marks where the pressure excursion
    // began. The accelerometer-only window can extend back through
    // calm flat-water riding before the pop, inflating airtime by
    // seconds; anchoring to the dip start keeps airtime honest.
    static const DIP_START_PA          = 8;

    // --- Debounce -----------------------------------------------------
    static const COAST_MS              = 1500;
    static const DISCARD_COAST_MS      = 300;

    static const G_MS2                  = 9.80665;

    // Internal G-magnitude ring. ~9 s at the 40 Hz poll rate, which
    // also covers ~8 s of real flight when the sensor updates at 25 Hz
    // (duplicate polls are stored; they are harmless for the scan).
    static const G_RING_CAPACITY       = 360;

    // Landing path codes (numeric to keep _lastJump strictly numeric —
    // see commit history for the mixed-type dictionary crash).
    // 0 = "impact" is the only production path in this design.
    static const LANDING_PATH_IMPACT    = 0;

    var _aggregator       as SensorAggregator;
    var _state            as Number;
    var _spikeCount       as Number;
    var _gRing            as Array<Float>;
    var _tsRing           as Array<Number>;
    var _ringCount        as Number;
    var _coastEndTs       as Number;
    var _lastJump         as Dictionary?;

    // PENDING candidate bookkeeping.
    var _pendTakeoffTs    as Number;
    var _pendLandingTs    as Number;
    var _pendAirtimeMs    as Number;

    function initialize(aggregator as SensorAggregator) {
        _aggregator       = aggregator;
        _state            = STATE_IDLE;
        _spikeCount       = 0;
        _gRing            = new Array<Float>[G_RING_CAPACITY];
        _tsRing           = new Array<Number>[G_RING_CAPACITY];
        _ringCount        = 0;
        _coastEndTs       = 0;
        _lastJump         = null;
        _pendTakeoffTs    = 0;
        _pendLandingTs    = 0;
        _pendAirtimeMs    = 0;
    }

    // Returns the most recently completed jump metrics, or null if no
    // jump has landed yet this session. Dictionary keys:
    //   :durationMs   Number   (takeoff -> landing)
    //   :heightM      Number   (barometric, ICAO on smoothed dip)
    //   :lengthM      Number
    //   :airtimeS     Float
    //   :startTs      Number
    //   :endTs        Number   (landing impact)
    //   :peakDeltaPa  Number
    //   :peakTs       Number
    //   :landingPathCode Number (0 = impact)

    function getLastJump() as Dictionary? {
        return _lastJump;
    }

    function getState() as Number {
        return _state;
    }

    function getStateName() as String {
        if (_state == STATE_IDLE)     { return "IDLE"; }
        if (_state == STATE_ARMED)    { return "ARMED"; }
        if (_state == STATE_PENDING)  { return "PENDING"; }
        if (_state == STATE_COASTING) { return "COASTING"; }
        return "UNKNOWN";
    }

    // Called by App.pollAccel() for every accelerometer sample.

    function onAccelSample(x as Float, y as Float, z as Float, when as Number) as Void {
        var g = _totalG(x, y, z);
        _pushRing(g, when);

        if (_state == STATE_IDLE) {
            if (_ringCount >= 8) {
                _state = STATE_ARMED;
                Logger.info("detector: IDLE -> ARMED");
            } else {
                return;
            }
        }

        if (_state == STATE_ARMED) {
            if (g >= LANDING_SPIKE_G) {
                _spikeCount++;
            } else {
                _spikeCount = 0;
            }
            if (_spikeCount >= LANDING_SPIKE_SAMPLES) {
                _spikeCount = 0;
                _analyzeLanding(when);
            }
            return;
        }

        if (_state == STATE_PENDING) {
            _maybeCompletePending(when);
            return;
        }

        if (_state == STATE_COASTING) {
            if (when >= _coastEndTs) {
                _state = STATE_ARMED;
                _spikeCount = 0;
                Logger.info("detector: COASTING -> ARMED");
            }
        }
    }

    // Called by App.pollPressure() at 1 Hz so the PENDING confirmation
    // window advances even if no accel sample arrives, and the COASTING
    // debounce can expire.

    function tick(when as Number) as Void {
        if (_state == STATE_PENDING) {
            _maybeCompletePending(when);
            return;
        }
        if (_state == STATE_COASTING && when >= _coastEndTs) {
            _state = STATE_ARMED;
            _spikeCount = 0;
            Logger.info("detector: COASTING -> ARMED");
        }
    }

    // ------------------------------------------------------------------
    // Internals
    // ------------------------------------------------------------------

    function _totalG(x as Float, y as Float, z as Float) as Float {
        var magSq = x * x + y * y + z * z;
        return Math.sqrt(magSq) / G_MS2;
    }

    // --- G ring ---------------------------------------------------------

    function _pushRing(g as Float, when as Number) as Void {
        var idx = _ringCount % G_RING_CAPACITY;
        _gRing[idx] = g;
        _tsRing[idx] = when;
        _ringCount++;
    }

    function _validCount() as Number {
        return _ringCount < G_RING_CAPACITY ? _ringCount : G_RING_CAPACITY;
    }

    function _ringIdx(i as Number) as Number {
        return (_ringCount - _validCount() + i) % G_RING_CAPACITY;
    }

    function _g(i as Number) as Float {
        return _gRing[_ringIdx(i)];
    }

    function _ts(i as Number) as Number {
        return _tsRing[_ringIdx(i)];
    }

    // --- Landing analysis ------------------------------------------------

    // A landing impact spike has just been confirmed. Walk back through
    // the G ring to find the quiet airborne window and the takeoff. On
    // success, transition to PENDING; otherwise take a short cooldown
    // and re-arm (the spike was chop, a pop, or a crash with no flight).

    function _analyzeLanding(when as Number) as Void {
        var V = _validCount();
        if (V < 4) {
            _shortDiscard(when, "noHistory");
            return;
        }

        // Walk back over the spike run itself.
        var k = V - 1;
        while (k >= 0 && _g(k) >= LANDING_SPIKE_G) {
            k--;
        }
        var i = k; // first sample before the spike run (may be -1)

        // Backward quiet-window scan. windowStart is the oldest
        // in-band sample of the current window; it stays at i+1 (empty)
        // until an in-band sample is seen.
        var windowStart = i + 1;
        var run = 0;
        var excursions = 0;
        var j = i;
        while (j >= 0) {
            if (when - _ts(j) > MAX_FLIGHT_MS) {
                break;
            }
            if (_g(j) <= AIRBORNE_G_HIGH) {
                run = 0;
                windowStart = j;
                j--;
            } else {
                run++;
                excursions++;
                if (run > EXCURSION_RUN_MAX || excursions > MAX_WINDOW_EXCURSIONS) {
                    // Sustained high-G = riding/edging. The window
                    // stops at the last in-band sample before it.
                    break;
                }
                j--;
            }
        }

        if (windowStart > i) {
            _shortDiscard(when, "noQuietWindow");
            return;
        }

        // Takeoff anchor: the first excursion inside the window is the
        // pop. If the window contains none, the takeoff is the window
        // start (soft pop below the excursion band).
        var takeoffIdx = windowStart;
        var m = windowStart;
        while (m <= i) {
            if (_g(m) > AIRBORNE_G_HIGH) {
                takeoffIdx = m;
                break;
            }
            m++;
        }

        var takeoffTs = _ts(takeoffIdx);
        var airtimeMs = when - takeoffTs;
        if (airtimeMs < MIN_FLIGHT_MS) {
            _shortDiscard(when, "shortWindow ms=" + airtimeMs);
            return;
        }

        // Reduced-G evidence inside the flight.
        var lowCount = 0;
        var minG = 10.0f;
        var q = takeoffIdx;
        while (q <= i) {
            var gq = _g(q);
            if (gq < minG) { minG = gq; }
            if (gq < FREEFALL_SOFT_G) { lowCount++; }
            q++;
        }
        if (lowCount == 0) {
            _shortDiscard(when, "noReducedG minG=" + minG.format("%.2f"));
            return;
        }

        _state         = STATE_PENDING;
        _pendTakeoffTs = takeoffTs;
        _pendLandingTs = when;
        _pendAirtimeMs = airtimeMs;
        Logger.info("JUMP CANDIDATE airborneMs=" + airtimeMs
            + " minG=" + minG.format("%.2f")
            + " lowCount=" + lowCount);
        Logger.info("detector: ARMED -> PENDING");
    }

    // --- PENDING completion ----------------------------------------------

    // Called from onAccelSample / tick once PENDING_MS has elapsed
    // after the landing impact. Runs the barometric dip-and-return
    // confirmation over the median-of-3 smoothed pressure series and
    // either records the jump or discards the candidate.

    function _maybeCompletePending(when as Number) as Void {
        if (_state != STATE_PENDING) {
            return;
        }
        if (when - _pendLandingTs < PENDING_MS) {
            return;
        }

        var sm = _smoothedPressureSeries();
        if (sm == null || sm.size() < 3) {
            _discardCandidate(when, "noPressureData");
            return;
        }

        // Baseline: median of smoothed samples in the pre-takeoff
        // window [takeoff - BASELINE_BACK_MS, takeoff - BASELINE_GAP_MS].
        var basePa = -1;
        var baseVals = [] as Array<Number>;
        for (var si = 0; si < sm.size(); si++) {
            var s = sm[si];
            if (s[:when] >= _pendTakeoffTs - BASELINE_BACK_MS
                    && s[:when] <= _pendTakeoffTs - BASELINE_GAP_MS) {
                baseVals.add(s[:pa]);
            }
        }
        if (baseVals.size() > 0) {
            basePa = _medianOf(baseVals);
        } else {
            // Fallback: the last smoothed sample at or before takeoff.
            for (var si = 0; si < sm.size(); si++) {
                var s = sm[si];
                if (s[:when] <= _pendTakeoffTs) {
                    basePa = s[:pa];
                }
            }
            if (basePa < 0) {
                _discardCandidate(when, "noBaseline");
                return;
            }
        }

        // Flight: lowest smoothed pressure strictly after takeoff and
        // up to the landing impact.
        var minPa = -1;
        var peakTs = 0;
        for (var si = 0; si < sm.size(); si++) {
            var s = sm[si];
            if (s[:when] > _pendTakeoffTs && s[:when] <= _pendLandingTs) {
                if (minPa < 0 || s[:pa] < minPa) {
                    minPa = s[:pa];
                    peakTs = s[:when];
                }
            }
        }
        if (minPa < 0) {
            _discardCandidate(when, "noFlightPressure");
            return;
        }

        var dip = basePa - minPa;
        if (dip < BARO_DIP_PA) {
            _discardCandidate(when, "noDip dip=" + dip);
            return;
        }

        // Takeoff refinement: anchor the takeoff to where the smoothed
        // pressure actually left the baseline. The accelerometer-only
        // window can extend back through calm flat-water riding before
        // the pop (airtime inflated by seconds - the 2026-09-11 test
        // session showed 8 s "airtimes" for ~2 s jumps). The baseline
        // above stays computed from the pre-refinement takeoff, which
        // is what we want: it samples the pre-jump riding level.
        var dipStartTs = _pendTakeoffTs;
        for (var si = 0; si < sm.size(); si++) {
            var s = sm[si];
            if (s[:when] > _pendTakeoffTs && s[:when] <= _pendLandingTs
                    && s[:pa] <= basePa - DIP_START_PA) {
                dipStartTs = s[:when];
                break;
            }
        }
        // Never push the takeoff later than landing - MIN_FLIGHT_MS so
        // refinement cannot shrink a real jump below the airtime gate.
        var capTs = _pendLandingTs - MIN_FLIGHT_MS;
        if (dipStartTs > capTs) {
            dipStartTs = capTs;
        }
        if (dipStartTs > _pendTakeoffTs) {
            Logger.info("detector: takeoff refined "
                + (_pendLandingTs - _pendTakeoffTs) + "ms -> "
                + (_pendLandingTs - dipStartTs) + "ms");
            _pendTakeoffTs = dipStartTs;
            _pendAirtimeMs = _pendLandingTs - dipStartTs;
        }

        // Return check: the latest post-landing smoothed sample must be
        // back near the baseline. This is the gate that rejects tack
        // ram-air drift (pressure steps down and STAYS down).
        var retVal = minPa;
        for (var si = 0; si < sm.size(); si++) {
            var s = sm[si];
            if (s[:when] > _pendLandingTs) {
                retVal = s[:pa];
            }
        }
        var drift = retVal - basePa;
        if (drift < 0) { drift = -drift; }
        if (drift > BARO_RETURN_PA) {
            _discardCandidate(when, "noReturn drift=" + drift);
            return;
        }

        // GPS speed gate: real jumps only happen from riding speed.
        // The last two fixes at/before takeoff (+1 s slack for the 1 Hz
        // fix rate) must show ground speed >= TAKEOFF_SPEED_MPS. With
        // no usable fix pair (GPS dropout) the gate is skipped rather
        // than discarding real jumps.
        var positions = _aggregator.getRecentPositions(32);
        var pALat = 0.0f;
        var pALon = 0.0f;
        var pAWhen = 0;
        var pBLat = 0.0f;
        var pBLon = 0.0f;
        var pBWhen = 0;
        var fixCount = 0;
        for (var pi = 0; pi < positions.size(); pi++) {
            if (positions[pi][:when] <= _pendTakeoffTs + 1000) {
                pALat = pBLat;
                pALon = pBLon;
                pAWhen = pBWhen;
                pBLat = positions[pi][:lat];
                pBLon = positions[pi][:lon];
                pBWhen = positions[pi][:when];
                fixCount++;
            }
        }
        if (fixCount >= 2) {
            var pdt = pBWhen - pAWhen;
            if (pdt > 0 && pdt <= 10000) {
                var pdist = _haversineMeters(pALat, pALon, pBLat, pBLon);
                var speed = pdist.toFloat() / (pdt.toFloat() / 1000.0);
                if (speed < TAKEOFF_SPEED_MPS) {
                    _discardCandidate(when, "slowAtTakeoff speed=" + speed.format("%.1f"));
                    return;
                }
            }
        }

        _recordJump(when, basePa, minPa, peakTs, dip);
    }

    // --- Recording ---------------------------------------------------------

    function _recordJump(when as Number, basePa as Number, minPa as Number,
                         peakTs as Number, dip as Number) as Void {
        var airtimeMs = _pendAirtimeMs;
        var airtimeS = airtimeMs.toFloat() / 1000.0;

        // Height from the pressure dip using the ICAO barometric
        // formula on the median-smoothed peak. h = 44330 * (1 - (P/P0)
        // ^ 0.190263) metres.
        var heightM = 0;
        if (basePa > 0 && minPa > 0) {
            var ratio = minPa.toDouble() / basePa.toDouble();
            if (ratio < 0.0) { ratio = 0.0; }
            if (ratio >= 1.0) { ratio = 0.999999; }
            if (ratio > 0.0) {
                heightM = (44330.0 * (1.0 - Math.pow(ratio, 0.190263))).toFloat();
            }
        }

        // Jump length: takeoff position = the last GPS fix at/before
        // takeoff (+1 s slack for the 1 Hz fix rate); landing position
        // = the latest fix.
        var tLat = 0.0f;
        var tLon = 0.0f;
        var haveTakeoff = false;
        var positions = _aggregator.getRecentPositions(32);
        for (var pi = 0; pi < positions.size(); pi++) {
            var p = positions[pi];
            if (p[:when] <= _pendTakeoffTs + 1000) {
                tLat = p[:lat];
                tLon = p[:lon];
                haveTakeoff = true;
            }
        }
        var lengthM = 0.0f;
        var lPos = _aggregator.getLatestPosition();
        if (haveTakeoff && lPos != null) {
            lengthM = _haversineMeters(tLat, tLon, lPos[:lat], lPos[:lon]);
        }

        try {
            _lastJump = {
                :durationMs      => airtimeMs,
                :heightM         => heightM,
                :lengthM          => lengthM,
                :airtimeS         => airtimeS,
                :startTs          => _pendTakeoffTs,
                :endTs            => _pendLandingTs,
                :peakDeltaPa      => dip,
                :peakTs           => peakTs,
                :landingPathCode  => LANDING_PATH_IMPACT
            };

            Logger.info(
                "JUMP LANDED ts=" + _pendLandingTs
                + " durationMs=" + airtimeMs
                + " heightM=" + heightM
            );
            Logger.info(
                "JUMP LANDED airtimeS=" + airtimeS.format("%.2f")
                + " lengthM=" + lengthM
                + " peakDeltaPa=" + dip
                + " baselinePa=" + basePa
                + " landingPath=impact"
            );
        } catch (e) {
            Logger.error("_recordJump: failed to record jump e=" + e);
            _lastJump = {
                :durationMs      => airtimeMs,
                :heightM         => 0,
                :lengthM          => 0.0f,
                :airtimeS         => airtimeS,
                :startTs          => _pendTakeoffTs,
                :endTs            => _pendLandingTs,
                :peakDeltaPa      => 0,
                :peakTs           => 0,
                :landingPathCode  => LANDING_PATH_IMPACT
            };
        }

        _enterCoasting(when, COAST_MS);
    }

    // --- Discards ----------------------------------------------------------

    // A landing-spike trigger with no valid airborne window behind it
    // (chop slap, pop, crash). Short cooldown so a pop does not blind
    // us to the real landing that follows within a second or two.

    function _shortDiscard(when as Number, reason as String) as Void {
        Logger.warn("detector: discard - " + reason);
        _enterCoasting(when, DISCARD_COAST_MS);
    }

    // A PENDING candidate that failed the barometric confirmation.

    function _discardCandidate(when as Number, reason as String) as Void {
        Logger.warn("detector: discard candidate - " + reason);
        _enterCoasting(when, DISCARD_COAST_MS);
    }

    function _enterCoasting(when as Number, ms as Number) as Void {
        _state = STATE_COASTING;
        _coastEndTs = when + ms;
        _spikeCount = 0;
    }

    // --- Pressure helpers ---------------------------------------------------

    // Median-of-3 causal smoothing over the raw 1 Hz pressure ring.
    // A single-sample splash spike (water hitting the port) cannot move
    // the smoothed value; a real multi-second climb can.

    function _smoothedPressureSeries() as Array<Dictionary>? {
        var raws = _aggregator.getRecentPressure(PRESSURE_LOOKBACK);
        var n = raws.size();
        if (n < 3) {
            return null;
        }
        var out = new Array<Dictionary>[n];
        for (var i = 0; i < n; i++) {
            var pa;
            if (i >= 2) {
                pa = _median3(raws[i - 2][:pa], raws[i - 1][:pa], raws[i][:pa]);
            } else {
                pa = raws[i][:pa];
            }
            out[i] = { :pa => pa, :when => raws[i][:when] };
        }
        return out;
    }

    function _median3(a as Number, b as Number, c as Number) as Number {
        if ((a <= b && b <= c) || (c <= b && b <= a)) { return b; }
        if ((b <= a && a <= c) || (c <= a && a <= b)) { return a; }
        return c;
    }

    function _medianOf(vals as Array<Number>) as Number {
        var n = vals.size();
        if (n == 0) { return 0; }
        if (n == 1) { return vals[0]; }
        var arr = new Array<Number>[n];
        for (var i = 0; i < n; i++) { arr[i] = vals[i]; }
        for (var i = 1; i < n; i++) {
            var key = arr[i];
            var j = i - 1;
            while (j >= 0 && arr[j] > key) {
                arr[j + 1] = arr[j];
                j--;
            }
            arr[j + 1] = key;
        }
        if (n % 2 == 1) {
            return arr[n / 2];
        }
        return (arr[n / 2 - 1] + arr[n / 2]) / 2;
    }

    // Great-circle distance between two lat/lon points, in metres.

    function _haversineMeters(lat1 as Float, lon1 as Float,
                              lat2 as Float, lon2 as Float) as Float {
        var R = 6371000.0;
        var toRad = 0.017453292519943295;
        var dLat = (lat2 - lat1) * toRad;
        var dLon = (lon2 - lon1) * toRad;
        var a1 = lat1 * toRad;
        var a2 = lat2 * toRad;
        var s1 = Math.sin(dLat / 2.0);
        var s2 = Math.sin(dLon / 2.0);
        var a = s1 * s1 + Math.cos(a1) * Math.cos(a2) * s2 * s2;
        var c = 2.0 * Math.atan2(Math.sqrt(a), Math.sqrt(1.0 - a));
        return (R * c).toFloat();
    }
}
