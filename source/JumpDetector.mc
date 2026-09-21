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
//   6. BARO      - raw pressure must show a dip-then-RETURN shape:
//                  >= BARO_DIP_PA below the pre-takeoff baseline during
//                  flight, and back within BARO_RETURN_PA of it after
//                  landing. A bare "dropped 20 Pa sometime in 20 s" no
//                  longer exists — the return check is what rejects tack
//                  ram-air drift and the wet-port decay.
//
//                  The barometer produces occasional wildly corrupt
//                  samples (water over the port: a +800 Pa spike then a
//                  -1300 Pa plunge, measured 2026-09-14). Every one of
//                  the three places pressure is read is hardened against
//                  a single bad sample WITHOUT smoothing the series:
//                    baseline - median over the pre-takeoff window
//                    dip      - second-lowest sample in the flight
//                    return   - post-landing sample closest to baseline
//                  Smoothing was tried (median-of-3) and had to go: at
//                  1 Hz it erased short jumps outright, since
//                  median(B, B, D) = B.
//   7. RECORD    - height from the ICAO formula on the second-lowest
//                  flight sample.
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
// Accelerometer unit note: App converts accelerometer milli-g values
// to m/s^2 before calling onAccelSample(), on both the stream path
// (onSensorData) and the poll fallback (pollAccel)
// (verified against the Connect IQ docs: accel is in millig-units).

import Toybox.Lang;
import Toybox.Math;

class JumpDetector {

    static const STATE_IDLE     = 0;
    static const STATE_ARMED    = 1;
    static const STATE_PENDING  = 2;
    static const STATE_COASTING = 3;

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
    // Applied at PENDING completion to the raw pressure series.
    // dip >= BARO_DIP_PA during flight AND a post-landing sample within
    // BARO_RETURN_PA of the pre-takeoff baseline. The return check is
    // what rejects tack ram-air drift and the wet-port decay.
    static const BARO_DIP_PA           = 18;
    static const BARO_RETURN_PA        = 30;
    static const BASELINE_BACK_MS      = 4000;
    static const BASELINE_GAP_MS       = 500;

    // Long enough for at least two post-landing pressure samples at the
    // 1 Hz worst case, so the return check below has something real to
    // compare against instead of falling back to the dip itself.
    static const PENDING_MS            = 2600;

    // ~20 s of history at the 4 Hz poll rate.
    static const PRESSURE_LOOKBACK     = 80;

    // Takeoff refinement: the first flight sample at least
    // this far below the baseline marks where the pressure excursion
    // began. The accelerometer-only window can extend back through
    // calm flat-water riding before the pop, inflating airtime by
    // seconds; anchoring to the dip start keeps airtime honest.
    static const DIP_START_PA          = 8;

    // --- Debounce -----------------------------------------------------
    static const COAST_MS              = 1500;
    static const DISCARD_COAST_MS      = 300;

    // A GPS fix further than this from the moment it is meant to
    // represent is not usable as a jump endpoint.
    static const POSITION_MATCH_MS      = 2000;

    static const G_MS2                  = 9.80665;

    // Internal G-magnitude ring. ~14 s at the 25 Hz stream rate,
    // which covers the 8 s backward scan with margin (duplicate
    // poll-loop samples are stored too; they are harmless for the
    // scan).
    static const G_RING_CAPACITY       = 360;

    // Landing path codes (numeric to keep _lastJump strictly numeric —
    // see commit history for the mixed-type dictionary crash).
    // 0 = "impact" is the only production path in this design.
    static const LANDING_PATH_IMPACT    = 0;

    // Discard reasons. Tallied per session and printed as one line at
    // session end: APP.TXT rotates at a few KB, so per-event warnings
    // are gone by the time a session is reviewed, and a 0-jump session
    // then says nothing about which gate rejected everything.
    static const DISCARD_NO_HISTORY      = 0;
    static const DISCARD_NO_QUIET_WINDOW = 1;
    static const DISCARD_SHORT_WINDOW    = 2;
    static const DISCARD_NO_REDUCED_G    = 3;
    static const DISCARD_NO_PRESSURE     = 4;
    static const DISCARD_NO_BASELINE     = 5;
    static const DISCARD_NO_FLIGHT_PA    = 6;
    static const DISCARD_NO_DIP          = 7;
    static const DISCARD_NO_RETURN       = 8;
    static const DISCARD_SLOW_TAKEOFF    = 9;
    static const DISCARD_REASON_COUNT    = 10;

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

    var _discardCounts    as Array<Number>;

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
        _discardCounts    = new Array<Number>[DISCARD_REASON_COUNT];
        for (var i = 0; i < DISCARD_REASON_COUNT; i++) { _discardCounts[i] = 0; }
    }

    // Clear all per-session state. Without this a begin/end/begin cycle
    // starts in whatever state the previous session ended in, with its
    // timestamps still in the rings.

    function reset() as Void {
        _state         = STATE_IDLE;
        _spikeCount    = 0;
        _ringCount     = 0;
        _coastEndTs    = 0;
        _lastJump      = null;
        _pendTakeoffTs = 0;
        _pendLandingTs = 0;
        _pendAirtimeMs = 0;
        for (var i = 0; i < DISCARD_REASON_COUNT; i++) { _discardCounts[i] = 0; }
    }

    function getDiscardCounts() as Array<Number> {
        return _discardCounts;
    }

    // Returns the most recently completed jump metrics, or null if no
    // jump has landed yet this session. Dictionary keys:
    //   :durationMs   Number   (takeoff -> landing)
    //   :heightM      Number   (barometric, ICAO on the flight dip)
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

    // Called by App.pollPressure() (4 Hz) so the PENDING confirmation
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
            _shortDiscard(when, DISCARD_NO_HISTORY, "noHistory");
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
            _shortDiscard(when, DISCARD_NO_QUIET_WINDOW, "noQuietWindow");
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
            _shortDiscard(when, DISCARD_SHORT_WINDOW, "shortWindow ms=" + airtimeMs);
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
            _shortDiscard(when, DISCARD_NO_REDUCED_G, "noReducedG minG=" + minG.format("%.2f"));
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
    // confirmation over the raw pressure series and either records the
    // jump or discards the candidate.
    //
    // This works on RAW samples, not a median-of-3 smoothed series. At
    // 1 Hz a median-of-3 erases a single-sample dip completely -
    // median(B, B, D) = B - so a short jump's only pressure evidence
    // disappeared before the dip gate ever saw it. Splash spikes are
    // rejected instead by taking the SECOND-smallest flight sample: a
    // water-on-the-port outlier is one sample, a real dip is not.

    function _maybeCompletePending(when as Number) as Void {
        if (_state != STATE_PENDING) {
            return;
        }
        if (when - _pendLandingTs < PENDING_MS) {
            return;
        }

        var raws = _aggregator.getRecentPressure(PRESSURE_LOOKBACK);
        if (raws.size() < 3) {
            _discardCandidate(when, DISCARD_NO_PRESSURE, "noPressureData");
            return;
        }

        // Baseline: median of the raw samples in the pre-takeoff window
        // [takeoff - BASELINE_BACK_MS, takeoff - BASELINE_GAP_MS]. The
        // median is already outlier-proof, so no pre-smoothing needed.
        var basePa = -1;
        var baseVals = [] as Array<Number>;
        for (var si = 0; si < raws.size(); si++) {
            var r = raws[si];
            if (r[:when] >= _pendTakeoffTs - BASELINE_BACK_MS
                    && r[:when] <= _pendTakeoffTs - BASELINE_GAP_MS) {
                baseVals.add(r[:pa]);
            }
        }
        if (baseVals.size() > 0) {
            basePa = _medianOf(baseVals);
        } else {
            // Fallback: median of the last few samples at or before
            // takeoff. Never a single raw sample - one bad read would
            // become the baseline every later gate is measured against.
            var tail = [] as Array<Number>;
            for (var si = 0; si < raws.size(); si++) {
                var r = raws[si];
                if (r[:when] <= _pendTakeoffTs) {
                    tail.add(r[:pa]);
                    if (tail.size() > 3) { tail = tail.slice(1, null); }
                }
            }
            if (tail.size() == 0) {
                _discardCandidate(when, DISCARD_NO_BASELINE, "noBaseline");
                return;
            }
            basePa = _medianOf(tail);
        }

        // Flight window: the two lowest raw samples strictly after
        // takeoff and up to the landing impact. minPa is the SECOND
        // lowest when the window holds more than one sample, so a
        // single splash outlier cannot set the height.
        var lowest = -1;
        var second = -1;
        var lowestTs = 0;
        var secondTs = 0;
        var flightCount = 0;
        for (var si = 0; si < raws.size(); si++) {
            var r = raws[si];
            if (r[:when] > _pendTakeoffTs && r[:when] <= _pendLandingTs) {
                flightCount++;
                var pa = r[:pa];
                if (lowest < 0 || pa < lowest) {
                    second = lowest;
                    secondTs = lowestTs;
                    lowest = pa;
                    lowestTs = r[:when];
                } else if (second < 0 || pa < second) {
                    second = pa;
                    secondTs = r[:when];
                }
            }
        }
        if (flightCount == 0) {
            _discardCandidate(when, DISCARD_NO_FLIGHT_PA, "noFlightPressure");
            return;
        }

        var minPa = lowest;
        var peakTs = lowestTs;
        if (flightCount > 1 && second >= 0) {
            minPa = second;
            peakTs = secondTs;
        }

        var dip = basePa - minPa;
        if (dip < BARO_DIP_PA) {
            _discardCandidate(when, DISCARD_NO_DIP,
                "noDip dip=" + dip + " n=" + flightCount);
            return;
        }

        // Return check: pressure must come back to the pre-takeoff
        // baseline after landing. This is the gate that rejects the
        // wet-port signature - a +800 Pa spike, a -1300 Pa plunge, then
        // a 15 s exponential decay that is still hundreds of Pa off
        // baseline (measured on the 2026-09-14 session) - and the tack
        // ram-air drift that steps down and STAYS down.
        //
        // Only a genuine post-landing sample counts. The old code
        // seeded the comparison with minPa, so a candidate with no
        // post-landing sample yet was measured against its own dip:
        // the bigger the jump, the likelier the false rejection.
        // Bad-read protection: take the post-landing sample CLOSEST to
        // the baseline rather than the last one. A lone corrupt sample
        // then cannot veto a jump whose pressure really did come back,
        // and it cannot rescue a wet-port decay either - during a decay
        // no sample is near baseline (the 2026-09-14 dunks were still
        // 400+ Pa off two seconds after the event).
        var drift = -1;
        for (var si = 0; si < raws.size(); si++) {
            var r = raws[si];
            if (r[:when] > _pendLandingTs) {
                var d = r[:pa] - basePa;
                if (d < 0) { d = -d; }
                if (drift < 0 || d < drift) { drift = d; }
            }
        }
        if (drift < 0) {
            _discardCandidate(when, DISCARD_NO_RETURN, "noReturn noPostLandingSample");
            return;
        }
        if (drift > BARO_RETURN_PA) {
            _discardCandidate(when, DISCARD_NO_RETURN, "noReturn drift=" + drift);
            return;
        }

        // Takeoff refinement: anchor the takeoff to where the pressure
        // actually left the baseline. The accelerometer-only window can
        // extend back through calm flat-water riding before the pop
        // (the 2026-09-11 session showed 8 s "airtimes" for ~2 s jumps).
        // The baseline stays computed from the pre-refinement takeoff,
        // which is what we want: it samples the pre-jump riding level.
        var dipStartTs = _pendTakeoffTs;
        for (var si = 0; si < raws.size(); si++) {
            var r = raws[si];
            if (r[:when] > _pendTakeoffTs && r[:when] <= _pendLandingTs
                    && r[:pa] <= basePa - DIP_START_PA) {
                dipStartTs = r[:when];
                break;
            }
        }
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

        // GPS speed gate: real jumps only happen from riding speed. A
        // stationary rider (wading out, body-dragging, water-start
        // attempts) produces kite-yank spikes and port-dunk dips that
        // otherwise pass every accelerometer/baro gate. With no usable
        // speed sample the gate is skipped rather than dropping real
        // jumps.
        var takeoffSpeed = _speedNearTakeoff();
        if (takeoffSpeed >= 0.0 && takeoffSpeed < TAKEOFF_SPEED_MPS) {
            _discardCandidate(when, DISCARD_SLOW_TAKEOFF,
                "slowAtTakeoff speed=" + takeoffSpeed.format("%.1f"));
            return;
        }

        _recordJump(when, basePa, minPa, peakTs, dip);
    }

    // Ground speed at takeoff, or -1.0 when GPS cannot answer.
    //
    // Prefers the speed the GPS reports directly; falls back to
    // differencing the two fixes bracketing takeoff. The fallback only
    // runs when no fix carries a speed, because differencing two 1 Hz
    // fixes reads 0 m/s whenever consecutive callbacks repeat a
    // position.

    function _speedNearTakeoff() as Float {
        var positions = _aggregator.getRecentPositions(32);
        var cutoff = _pendTakeoffTs + 1000;

        var reported = -1.0f;
        var pALat = 0.0f;
        var pALon = 0.0f;
        var pAWhen = 0;
        var pBLat = 0.0f;
        var pBLon = 0.0f;
        var pBWhen = 0;
        var fixCount = 0;

        for (var pi = 0; pi < positions.size(); pi++) {
            var p = positions[pi];
            if (p[:when] > cutoff) { continue; }
            var sp = p[:speed];
            if (sp != null && sp >= 0.0) { reported = sp; }
            pALat = pBLat;
            pALon = pBLon;
            pAWhen = pBWhen;
            pBLat = p[:lat];
            pBLon = p[:lon];
            pBWhen = p[:when];
            fixCount++;
        }

        if (reported >= 0.0) {
            return reported;
        }
        if (fixCount >= 2) {
            var pdt = pBWhen - pAWhen;
            if (pdt > 0 && pdt <= 10000) {
                var pdist = _haversineMeters(pALat, pALon, pBLat, pBLon);
                return pdist.toFloat() / (pdt.toFloat() / 1000.0);
            }
        }
        return -1.0f;
    }

    // --- Recording ---------------------------------------------------------

    function _recordJump(when as Number, basePa as Number, minPa as Number,
                         peakTs as Number, dip as Number) as Void {
        var airtimeMs = _pendAirtimeMs;
        var airtimeS = airtimeMs.toFloat() / 1000.0;

        // Height from the pressure dip using the ICAO barometric
        // formula. h = 44330 * (1 - (P/P0) ^ 0.190263) metres.
        var heightM = 0;
        if (basePa > 0 && minPa > 0) {
            var ratio = minPa.toDouble() / basePa.toDouble();
            if (ratio < 0.0) { ratio = 0.0; }
            if (ratio >= 1.0) { ratio = 0.999999; }
            if (ratio > 0.0) {
                heightM = (44330.0 * (1.0 - Math.pow(ratio, 0.190263))).toFloat();
            }
        }

        // Jump length: the fix nearest takeoff to the fix nearest
        // landing, each required within POSITION_MATCH_MS of its anchor.
        //
        // The previous version ran from "last fix before takeoff + 1 s"
        // to getLatestPosition(). _recordJump runs PENDING_MS after the
        // landing impact, so the latest fix is seconds past landing and
        // every length carried ~3.5 s of riding with it - 35-40 m at
        // kite speeds, enough to trip the 100 m sanity cap on a real
        // jump.
        var positions = _aggregator.getRecentPositions(32);
        var takeoffFix = _fixNearest(positions, _pendTakeoffTs);
        var landingFix = _fixNearest(positions, _pendLandingTs);

        // A jump shorter than the GPS fix interval can put both anchors
        // on the SAME fix, which would report 0 m for a real jump. Fall
        // back to bracketing it - last fix at or before takeoff, first
        // at or after landing. That overstates by up to one fix
        // interval, but it is a measurement rather than a zero.
        if (takeoffFix != null && landingFix != null
                && takeoffFix[:when] == landingFix[:when]) {
            takeoffFix = _fixAtOrBefore(positions, _pendTakeoffTs);
            landingFix = _fixAtOrAfter(positions, _pendLandingTs);
        }

        var lengthM = 0.0f;
        if (takeoffFix != null && landingFix != null
                && takeoffFix[:when] != landingFix[:when]) {
            lengthM = _haversineMeters(
                takeoffFix[:lat], takeoffFix[:lon],
                landingFix[:lat], landingFix[:lon]);
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

    function _shortDiscard(when as Number, code as Number, reason as String) as Void {
        _discardCounts[code]++;
        Logger.warn("detector: discard - " + reason);
        _enterCoasting(when, DISCARD_COAST_MS);
    }

    // A PENDING candidate that failed the barometric confirmation.

    function _discardCandidate(when as Number, code as Number, reason as String) as Void {
        _discardCounts[code]++;
        Logger.warn("detector: discard candidate - " + reason);
        _enterCoasting(when, DISCARD_COAST_MS);
    }

    function _enterCoasting(when as Number, ms as Number) as Void {
        _state = STATE_COASTING;
        _coastEndTs = when + ms;
        _spikeCount = 0;
    }

    // --- Pressure helpers ---------------------------------------------------

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

    // The fix closest to `ts`, or null when the nearest is further away
    // than POSITION_MATCH_MS.

    function _fixNearest(positions as Array<Dictionary>, ts as Number) as Dictionary? {
        var best = null;
        var bestGap = POSITION_MATCH_MS + 1;
        for (var i = 0; i < positions.size(); i++) {
            var p = positions[i];
            var gap = p[:when] - ts;
            if (gap < 0) { gap = -gap; }
            if (gap < bestGap) {
                bestGap = gap;
                best = p;
            }
        }
        return best;
    }

    // Latest fix at or before `ts`, within POSITION_MATCH_MS.

    function _fixAtOrBefore(positions as Array<Dictionary>, ts as Number) as Dictionary? {
        var best = null;
        for (var i = 0; i < positions.size(); i++) {
            var p = positions[i];
            if (p[:when] <= ts && ts - p[:when] <= POSITION_MATCH_MS) {
                if (best == null || p[:when] > best[:when]) { best = p; }
            }
        }
        return best;
    }

    // Earliest fix at or after `ts`, within POSITION_MATCH_MS.

    function _fixAtOrAfter(positions as Array<Dictionary>, ts as Number) as Dictionary? {
        var best = null;
        for (var i = 0; i < positions.size(); i++) {
            var p = positions[i];
            if (p[:when] >= ts && p[:when] - ts <= POSITION_MATCH_MS) {
                if (best == null || p[:when] < best[:when]) { best = p; }
            }
        }
        return best;
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
