// JumpDetector
//
// Phase 2 step 2. A small state machine that consumes accelerometer
// (and opportunistically pressure / GPS) samples from the
// SensorAggregator and recognises kite jumps. The recogniser is
// deliberately conservative: a jump must show a sustained launch
// spike, a quiet flight phase, and either a pressure return or a
// low GPS speed before it is declared landed.
//
// States
//   IDLE     - waiting for the aggregator to accumulate enough
//              accelerometer samples to make thresholding meaningful.
//   ARMED    - watching for a sustained total-G launch spike.
//   AIRBORNE - jump in flight; tracking peak altitude (lowest Pa).
//   LANDING  - one-tick transitional state that records the landing
//              timestamp and emits the JUMP LANDED log line.
//   COASTING - debounce window (COAST_MS) before re-arming so the
//              same jump cannot trigger twice.
//
// All log lines are emitted through Logger so the verification
// harness can scrape them out of the simulator log.

import Toybox.Lang;
import Toybox.Math;

class JumpDetector {

    static const STATE_IDLE     = 0;
    static const STATE_ARMED    = 1;
    static const STATE_AIRBORNE = 2;
    static const STATE_LANDING  = 3;
    static const STATE_COASTING = 4;

    // 25 Hz accelerometer; 3 consecutive samples ~= 120 ms.
    // Takeoff threshold ~1.10 G (soft over-correction; sub-1m jumps are filtered by SessionManager).
    static const TAKEOFF_G            = 1.10;
    // Landing threshold ~1.15 G (most landings drop below 1G briefly on impact).
    static const LANDING_G            = 1.15;
    // Takeoff requires sustained spike (3 samples ~120 ms).
    static const TAKEOFF_SAMPLES      = 3;
    // Landing requires sustained low-G + a freefall confirmation in between.
    static const LANDING_SAMPLES      = 3;
    // Freefall confirmation: mid-flight total-G must drop below this for
    // at least FREEFALL_SAMPLES consecutive samples (~40 ms at 25 Hz).
    static const FREEFALL_G           = 1.05;
    static const FREEFALL_SAMPLES     = 1;
    static const G_MS2                = 9.80665;
    static const COAST_MS             = 1500;

    // Landing corroboration. Pressure is considered "returned" when
    // current reading is within this many Pa of the pre-jump baseline
    // (~20 Pa ~= 1.7 m at sea level — wide enough to accept a soft
    // landing that does not return exactly to the takeoff baseline).
    // GPS speed in m/s below which we trust the rider is on the ground
    // (or at least not travelling under kite power).
    static const PRESSURE_RETURN_PA   = 20;
    static const GPS_SPEED_LOW_MPS    = 1.5;

    // Descent-rate threshold (Pa/s) for declaring the descent "flat"
    // after pressure has returned to baseline. ~5 Pa/s ~= 0.4 m/s.
    static const DESCENT_FLAT_PA_S    = 5;

    // Single-sample pressure drop larger than this is treated as a
    // water splash / sensor glitch and ignored when tracking the
    // jump peak. ~500 Pa ≈ 40 m at sea level — large enough to
    // accept any realistic kite jump in one 1 Hz sample while still
    // rejecting the 300 m+ / ~3600 Pa spikes seen in real-watch logs.
    static const SPLASH_OUTLIER_PA    = 500;

    // Pressure-history ring buffer size (samples). At 1 Hz pressure
    // updates this gives a ~4 s window for descent-rate calculation.
    static const PRESSURE_HISTORY_SIZE = 4;

    // Maximum allowed airborne duration before forcing a landing. Kite
    // jumps are typically under 10 s; 30 s is a generous safety net so
    // a stuck detector cannot permanently lose the jump.
    static const MAX_FLIGHT_MS        = 20000;

    // Minimum airborne duration before any landing path can fire.
    // Sub-second events (e.g. a wind gust lifting the rider briefly,
    // a hard bar yank, or a wrist impact) are not real jumps. Without
    // this guard the pressure / GPS / lowG paths can collapse a real
    // 200-900 ms "hop" into a recorded jump, wasting UI / FIT budget
    // and surfacing a misleading SummaryView popup. The 30 s
    // MAX_FLIGHT_MS timeout is unaffected; it remains the upper bound
    // for forcing a landing.
    static const MIN_FLIGHT_MS        = 1000;

    // Hybrid filter: minimum pressure drop (in Pa) from the pre-jump
    // baseline that must be observed during the airborne phase before
    // any landing path (or the timeout safety net) can record a jump.
    // This is the second of two gates in the "hybrid jump-detection
    // filter" (the first being MIN_FLIGHT_MS). A 20 Pa drop corresponds
    // to roughly 1.7 m of climb at sea level. If the rider did not
    // actually leave the ground by at least that margin — typically
    // because the takeoff was a hop, a bar yank, or the barometer was
    // already noisy — the jump is discarded and the detector re-arms
    // for the next real takeoff. Without this gate, a long enough
    // AIRBORNE window (1 s+) can be satisfied by sustained low-G
    // (e.g. hanging on the bar at low kite power) without any actual
    // altitude change, producing bogus sessions full of "jumps" with
    // zero height.
    static const TAKEOFF_PRESSURE_DROP_PA = 20;

    // GPS speed must stay below GPS_SPEED_LOW_MPS for at least this
    // long (in ms) before the GPS path can declare a landing.
    static const GPS_LOW_FOR_LAND_MS  = 500;

    var _aggregator       as SensorAggregator;
    var _state            as Number;
    var _aboveCount       as Number;
    var _belowCount       as Number;
    var _freefallCount    as Number;
    var _freefallConfirmed as Boolean;
    var _jumpStartTs      as Number;
    var _peakTs           as Number;
    var _baselinePressure as Number;
    var _minPressure      as Number;
    var _landingPressure  as Number;
    var _coastEndTs       as Number;
    var _takeoffLat       as Float;
    var _takeoffLon       as Float;
    var _landingLat       as Float;
    var _landingLon       as Float;
    var _lastJump         as Dictionary?;
    var _pressureHistory  as Array<Dictionary>;
    var _pressureHistoryHead as Number;
    var _pressureHistorySize as Number;
    var _gpsLowSinceTs    as Number;
    var _lastLandingPath  as String;

    function initialize(aggregator as SensorAggregator) {
        _aggregator       = aggregator;
        _state            = STATE_IDLE;
        _aboveCount       = 0;
        _belowCount       = 0;
        _freefallCount    = 0;
        _freefallConfirmed = false;
        _jumpStartTs      = 0;
        _peakTs           = 0;
        _baselinePressure = 0;
        _minPressure      = 0;
        _landingPressure  = 0;
        _coastEndTs       = 0;
        _takeoffLat       = 0.0f;
        _takeoffLon       = 0.0f;
        _landingLat       = 0.0f;
        _landingLon       = 0.0f;
        _lastJump         = null;
        _pressureHistory  = new Array<Dictionary>[PRESSURE_HISTORY_SIZE];
        _pressureHistoryHead = 0;
        _pressureHistorySize = 0;
        _gpsLowSinceTs    = 0;
        _lastLandingPath  = "";
        // Defensive: reset the pressure-history ring to empty so any
        // stale entries from a previous instance cannot feed into the
        // descent-rate calculation.
        _pressureHistoryHead = 0;
        _pressureHistorySize = 0;
    }

    // Returns the most recently completed jump metrics, or null if no
    // jump has landed yet this session. Dictionary keys:
    //   :durationMs   Number
    //   :heightM      Number   (barometric, ICAO on _minPressure)
    //   :lengthM      Number
    //   :airtimeS     Float
    //   :startTs      Number
    //   :endTs        Number
    //   :peakDeltaPa  Number

    function getLastJump() as Dictionary? {
        return _lastJump;
    }

    function getState() as Number {
        return _state;
    }

    function getStateName() as String {
        if (_state == STATE_IDLE)     { return "IDLE"; }
        if (_state == STATE_ARMED)    { return "ARMED"; }
        if (_state == STATE_AIRBORNE) { return "AIRBORNE"; }
        if (_state == STATE_LANDING)  { return "LANDING"; }
        if (_state == STATE_COASTING) { return "COASTING"; }
        return "UNKNOWN";
    }

    // Called by App.onSensor() for every accelerometer sample.

    function onAccelSample(x as Float, y as Float, z as Float, when as Number) as Void {
        var g = _totalG(x, y, z);

        if (_state == STATE_IDLE) {
            // Wait until the aggregator has buffered enough samples for
            // threshold checks to mean anything.
            if (_aggregator.getAccelCount() >= TAKEOFF_SAMPLES) {
                _state = STATE_ARMED;
                Logger.info("detector: IDLE -> ARMED");
            } else {
                return;
            }
        }

        if (_state == STATE_ARMED) {
            if (g >= TAKEOFF_G) {
                _aboveCount++;
                if (_aboveCount >= TAKEOFF_SAMPLES) {
                    _enterAirborne(when, g);
                }
            } else {
                _aboveCount = 0;
            }
            return;
        }

        if (_state == STATE_AIRBORNE) {
            // Track lowest pressure seen (= highest altitude). The
            // instant of lowest pressure is the exact peak altitude;
            // record its timestamp so the accel height formula can
            // split the flight into ascent and descent phases.
            var p = _aggregator.getLatestPressure();
            if (p != null) {
                // Track lowest pressure (= highest altitude). Reject
                // single-sample splash outliers that are dramatically
                // lower than the current minimum; everything else is
                // allowed to update the peak.
                if (_minPressure == 0) {
                    _minPressure = p[:pa];
                    _peakTs = when;
                } else if (p[:pa] < _minPressure - SPLASH_OUTLIER_PA) {
                    // Single-sample water/splash glitch — ignore.
                } else if (p[:pa] < _minPressure) {
                    _minPressure = p[:pa];
                    _peakTs = when;
                }
                // Append to the pressure-history ring (capped at
                // PRESSURE_HISTORY_SIZE). Deduplicate consecutive
                // entries with the same Pa value so the 40 Hz accel
                // poll does not fill the buffer with duplicates of
                // the same 1 Hz pressure reading.
                if (_pressureHistorySize == 0
                        || _pressureHistory[(_pressureHistoryHead - 1) % PRESSURE_HISTORY_SIZE][:pa] != p[:pa]) {
                    _pressureHistory[_pressureHistoryHead % PRESSURE_HISTORY_SIZE] = {
                        :pa => p[:pa], :when => when
                    };
                    _pressureHistoryHead++;
                    if (_pressureHistorySize < PRESSURE_HISTORY_SIZE) {
                        _pressureHistorySize++;
                    }
                }
            }
            // Freefall confirmation
            if (g < FREEFALL_G) {
                _freefallCount++;
                if (_freefallCount >= FREEFALL_SAMPLES) {
                    _freefallConfirmed = true;
                }
            } else {
                _freefallCount = 0;
            }

            // Low-G impact count for the existing landing branch.
            if (g < LANDING_G) {
                _belowCount++;
            } else {
                _belowCount = 0;
            }

            // Evaluate all landing paths each tick. Only one of them
            // (pressure / gps / lowG) can win because _enterLanding
            // immediately transitions out of AIRBORNE.
            _maybeLand(when);
            return;
        }

        if (_state == STATE_COASTING) {
            if (when >= _coastEndTs) {
                _state = STATE_ARMED;
                _aboveCount = 0;
                _belowCount = 0;
                Logger.info("detector: COASTING -> ARMED");
            }
        }
    }

    // Called by App.onPosition() (and could be wired into any other
    // non-accelerometer tick) so the COASTING debounce can advance,
    // and the AIRBORNE timeout can fire even if no accel sample has
    // arrived since the detector got stuck.

    function tick(when as Number) as Void {
        if (_state == STATE_AIRBORNE
                && _jumpStartTs > 0
                && (when - _jumpStartTs) > MAX_FLIGHT_MS) {
            _forceLanding(when, "maxFlightMs");
            return;
        }
        if (_state == STATE_COASTING && when >= _coastEndTs) {
            _state = STATE_ARMED;
            _aboveCount = 0;
            _belowCount = 0;
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

    function _enterAirborne(when as Number, takeoffG as Float) as Void {
        _state = STATE_AIRBORNE;
        _jumpStartTs = when;
        // Reset _peakTs so each jump starts with no known peak. The
        // AIRBORNE branch updates _peakTs on every strict pressure drop.
        _peakTs = 0;
        _belowCount  = 0;
        _freefallCount    = 0;
        _freefallConfirmed = false;
        _minPressure = 0;
        // Snapshot the pre-jump pressure so we can compute the climb
        // delta at landing time.
        var p = _aggregator.getLatestPressure();
        if (p != null) {
            _baselinePressure = p[:pa];
        } else {
            _baselinePressure = 0;
        }
        // Reset the pressure-history ring and seed it with the current
        // baseline so the descent-rate helper returns 0 until a fresh
        // 1 Hz sample arrives.
        _resetPressureHistory();
        if (_baselinePressure > 0) {
            _pressureHistory[0] = { :pa => _baselinePressure, :when => when };
            _pressureHistoryHead = 1;
            _pressureHistorySize = 1;
        }
        // Reset the landing-path tracker so a previous jump's path can
        // never leak into the next jump's log line or dictionary entry.
        _lastLandingPath = "";
        // Reset the GPS-low tracker so a leftover low-signal window from
        // before takeoff cannot satisfy GPS_LOW_FOR_LAND_MS in the first
        // few samples after we enter AIRBORNE.
        _gpsLowSinceTs = 0;
        // Snapshot takeoff GPS coordinates for jump length.
        var pos = _aggregator.getLatestPosition();
        if (pos != null) {
            _takeoffLat = pos[:lat];
            _takeoffLon = pos[:lon];
        } else {
            _takeoffLat = 0.0;
            _takeoffLon = 0.0;
        }
        Logger.info("JUMP AIRBORNE ts=" + when
            + " takeoffG=" + takeoffG.format("%.2f")
            + " baselinePa=" + _baselinePressure);
        Logger.info("detector: ARMED -> AIRBORNE");
    }

    function _maybeLand(when as Number) as Void {
        if (_state != STATE_AIRBORNE) {
            return;
        }

        // Minimum-airtime guard. Sub-second "jumps" (e.g. a wind gust
        // lifting the rider briefly, or a wrist impact) cannot trigger
        // any of the landing paths below. The pressure / GPS / lowG
        // paths are all evaluated together, so this single early
        // return covers all three. The 30 s MAX_FLIGHT_MS watchdog
        // lives in tick() and is unaffected: it remains the upper
        // bound that forces a landing if none of the normal paths
        // ever close.
        if ((when - _jumpStartTs) < MIN_FLIGHT_MS) {
            Logger.warn("detector: sub-1s landing ignored elapsedMs=" + (when - _jumpStartTs));
            return;
        }

        // Hybrid filter gate #2: require a real altitude change. After
        // the 1 s minimum flight has elapsed, check that the rider
        // actually left the ground by at least TAKEOFF_PRESSURE_DROP_PA.
        // Without this gate a sustained low-G window (e.g. hanging on
        // the bar at low kite power, or a long pause with the bar held
        // down) can pass MIN_FLIGHT_MS without any climb ever happening,
        // and the pressure / GPS / lowG paths below would happily
        // declare a "jump" with zero height. Discard immediately and
        // re-arm so the detector does not stay locked out for the
        // remaining airborne window.
        //
        // Use _minPressure (lowest Pa seen during flight = highest
        // altitude) rather than the current pressure. By the time
        // _maybeLand fires the rider is back near the ground and the
        // current pressure has already returned close to baseline; the
        // peak altitude is what determines whether a real jump
        // happened.
        var cur = _aggregator.getLatestPressure();
        var pressureDrop = 0;
        if (_baselinePressure > 0 && _minPressure > 0) {
            pressureDrop = _baselinePressure - _minPressure;
        }
        if (pressureDrop < TAKEOFF_PRESSURE_DROP_PA) {
            Logger.warn("detector: discard no pressure drop elapsedMs=" + (when - _jumpStartTs)
                + " pressureDropPa=" + pressureDrop
                + " requiredPa=" + TAKEOFF_PRESSURE_DROP_PA);
            _discardJump("no pressure drop after 1s (drop=" + pressureDrop + "Pa)");
            return;
        }

        // --- Path A: barometric pressure returned and descent flattened
        var pressureReturned = false;
        if (cur != null && _baselinePressure > 0) {
            var delta = cur[:pa] - _baselinePressure;
            if (delta < 0) { delta = -delta; }
            if (delta <= PRESSURE_RETURN_PA) {
                pressureReturned = true;
            }
        }
        // Only evaluate the descent-rate once we have at least 2 pressure
        // samples in the ring (one seeded at takeoff plus one fresh 1 Hz
        // reading). With fewer samples the helper returns 0.0f and the
        // pressure path could false-positive land on the very first tick
        // of AIRBORNE — which is the bug we are fixing here.
        var descentFlat = false;
        if (pressureReturned && _pressureHistorySize >= 2) {
            var rate = _descentRatePaS(when);
            var absRate = rate < 0.0 ? -rate : rate;
            descentFlat = absRate <= DESCENT_FLAT_PA_S;
        }

        // --- Path B: GPS speed low for GPS_LOW_FOR_LAND_MS
        var gpsSlowNow = false;
        var recent = _aggregator.getRecentPositions(2);
        if (recent.size() == 2) {
            var dt = (recent[1][:when] - recent[0][:when]).toFloat() / 1000.0;
            if (dt > 0.0) {
                var dist = _haversineMeters(
                    recent[0][:lat], recent[0][:lon],
                    recent[1][:lat], recent[1][:lon]
                );
                var speed = dist / dt;
                if (speed < GPS_SPEED_LOW_MPS) {
                    gpsSlowNow = true;
                }
            }
        }
        if (gpsSlowNow) {
            if (_gpsLowSinceTs == 0) {
                _gpsLowSinceTs = when;
            }
        } else {
            _gpsLowSinceTs = 0;
        }
        var gpsSlowForLongEnough = false;
        if (_gpsLowSinceTs > 0 && (when - _gpsLowSinceTs) >= GPS_LOW_FOR_LAND_MS) {
            gpsSlowForLongEnough = true;
        }

        // --- Path C: existing low-G impact (still requires freefall confirmation)
        var lowGFor3Samples = (_belowCount >= LANDING_SAMPLES);

        // Decide which path wins. Pressure is the preferred (and most
        // common) path because it works on smooth landings; GPS is a
        // backup when barometer is unavailable; lowG is the legacy
        // path that requires a real impact spike + freefall proof +
        // corroboration (pressure or GPS), just like the original code.
        var path = "";
        if (pressureReturned && descentFlat) {
            path = "pressure";
        } else if (gpsSlowForLongEnough) {
            path = "gps";
        } else if (lowGFor3Samples && _freefallConfirmed
                   && (pressureReturned || gpsSlowForLongEnough)) {
            path = "lowG";
        }

        if (path.equals("")) {
            // No landing path has fired yet; stay in AIRBORNE.
            return;
        }

        _lastLandingPath = path;
        Logger.info("detector: landing path=" + path);

        if (cur != null) {
            _landingPressure = cur[:pa];
        } else {
            _landingPressure = 0;
        }
        _enterLanding(when);
    }

    // Average pressure change (Pa/s) across the most recent pair of
    // samples in the pressure-history ring. Positive = pressure rising
    // (rider descending back toward ground). Returns 0.0 if there is
    // not enough history to compute a rate.
    //
    // Defensive: uses `_modPositive` so a negative `_pressureHistoryHead`
    // (which can occur after head wrap-around if the ring ever ran in
    // reverse) cannot produce a negative array index, and returns 0.0
    // if either ring slot has not yet been written.

    function _descentRatePaS(when as Number) as Float {
        if (_pressureHistorySize < 2) {
            return 0.0f;
        }
        var oldestPos = _pressureHistoryHead - _pressureHistorySize;
        var newestPos = _pressureHistoryHead - 1;
        var oldestIdx = _modPositive(oldestPos, PRESSURE_HISTORY_SIZE);
        var newestIdx = _modPositive(newestPos, PRESSURE_HISTORY_SIZE);
        var a = _pressureHistory[oldestIdx];
        var b = _pressureHistory[newestIdx];
        if (a == null || b == null) {
            return 0.0f;
        }
        var dt = (b[:when] - a[:when]).toFloat() / 1000.0;
        if (dt <= 0.0) {
            return 0.0f;
        }
        var dp = (b[:pa] - a[:pa]).toFloat();
        return dp / dt;
    }

    // Non-negative modulo. Monkey C's `%` operator returns a negative
    // result when the left operand is negative (e.g. `-1 % 4 == -1`),
    // which would produce a negative array index in
    // `_descentRatePaS()`. We never want a negative index, so this
    // helper unconditionally rewrites the result into `[0, m)`.

    function _modPositive(n as Number, m as Number) as Number {
        var r = n % m;
        while (r < 0) { r += m; }
        return r;
    }

    // Reset the pressure-history ring to an empty state. Called from
    // `initialize()` and `_enterAirborne()` so stale entries from a
    // previous jump can never feed the descent-rate calculation. Reads
    // in `_descentRatePaS()` null-check both slots, so we do not need
    // to overwrite each element here — just reset the head and size.

    function _resetPressureHistory() as Void {
        _pressureHistoryHead = 0;
        _pressureHistorySize = 0;
    }

    // Force a landing without corroboration. Used by the AIRBORNE
    // timeout to recover a jump that the other paths failed to close.
    //
    // Hybrid filter gate #2 (mirror of the check in _maybeLand): the
    // 30 s timeout is a safety net for stuck detectors, not a licence
    // to record a bogus jump with no altitude change. If the rider
    // never produced the required pressure drop (e.g. the takeoff was
    // a sustained hang on the bar with the kite parked), we discard
    // and re-arm instead of writing a fake session row.
    function _forceLanding(when as Number, reason as String) as Void {
        if (_state != STATE_AIRBORNE) {
            return;
        }
        var cur = _aggregator.getLatestPressure();
        var pressureDrop = 0;
        if (_baselinePressure > 0 && _minPressure > 0) {
            pressureDrop = _baselinePressure - _minPressure;
        }
        if (pressureDrop < TAKEOFF_PRESSURE_DROP_PA) {
            Logger.warn("detector: timeout discard no pressure drop elapsedMs=" + (when - _jumpStartTs)
                + " pressureDropPa=" + pressureDrop
                + " requiredPa=" + TAKEOFF_PRESSURE_DROP_PA
                + " reason=" + reason);
            _discardJump("timeout with no pressure drop (drop=" + pressureDrop + "Pa)");
            return;
        }
        if (cur != null) {
            _landingPressure = cur[:pa];
        } else {
            _landingPressure = 0;
        }
        _lastLandingPath = "timeout";
        Logger.warn("detector: AIRBORNE timeout, forcing landing reason=" + reason);
        _enterLanding(when);
    }

    // Discard the in-flight jump and re-arm the detector. Used by both
    // the MIN_FLIGHT_MS / pressure-drop gate in _maybeLand and the
    // matching gate in _forceLanding. The detector must not retain any
    // trace of the discarded jump: clear _lastJump so App._checkForLandedJump
    // (which polls getLastJump every accel tick) does not push a
    // SummaryView popup, clear _jumpStartTs so the next takeoff gets a
    // fresh start timestamp, and zero the low-G / freefall counters
    // so a leftover count from the discarded jump cannot satisfy the
    // landing paths of the next jump on its very first tick.
    function _discardJump(reason as String) as Void {
        Logger.info("detector: discarding jump - " + reason);
        _state            = STATE_ARMED;
        _lastJump         = null;
        _jumpStartTs      = 0;
        _aboveCount       = 0;
        _belowCount       = 0;
        _freefallCount    = 0;
        _freefallConfirmed = false;
        _baselinePressure = 0;
        _minPressure      = 0;
        _peakTs           = 0;
        _gpsLowSinceTs    = 0;
        _lastLandingPath  = "";
        _resetPressureHistory();
    }

    function _enterLanding(when as Number) as Void {
        _state = STATE_LANDING;
        // Defensive: if a code path reaches _enterLanding without setting
        // _lastLandingPath (e.g. a future direct call), default it to a
        // non-empty sentinel so the log line and dictionary entry are
        // always populated.
        if (_lastLandingPath == null || _lastLandingPath.equals("")) {
            _lastLandingPath = "unknown";
        }
        Logger.info("detector: AIRBORNE -> LANDING (path=" + _lastLandingPath + ")");
        var duration = when - _jumpStartTs;
        var peakDelta = 0;
        if (_baselinePressure > 0 && _minPressure > 0) {
            peakDelta = _baselinePressure - _minPressure;
        }

        // Capture landing GPS coordinates for jump length.
        var pos = _aggregator.getLatestPosition();
        if (pos != null) {
            _landingLat = pos[:lat];
            _landingLon = pos[:lon];
        } else {
            _landingLat = _takeoffLat;
            _landingLon = _takeoffLon;
        }

        // Height from pressure delta using the ICAO barometric formula.
        // h = 44330 * (1 - (P / P0) ^ (1 / 5.255)) metres.
        // Use _minPressure (lowest Pa = highest altitude reached during
        // flight) rather than _landingPressure, which is back near the
        // baseline by the time we land.
        var heightM = 0;
        if (_baselinePressure > 0 && _minPressure > 0) {
            var ratio = _minPressure.toDouble() / _baselinePressure.toDouble();
            // Clamp ratio into (0, 1) before Math.pow. Without this, a
            // floating-point noise floor or a pressure sensor glitch
            // could push ratio to >= 1.0 (or <= 0.0), which produces a
            // negative or NaN height and a confusing log line. The
            // companion .equals() check is redundant with the clamp but
            // kept for clarity.
            if (ratio < 0.0) { ratio = 0.0; }
            if (ratio >= 1.0) { ratio = 0.999999; }
            if (ratio > 0.0) {
                heightM = (44330.0 * (1.0 - Math.pow(ratio, 0.190263))).toFloat();
            }
        }

        // Length from Haversine of takeoff-to-landing positions.
        var lengthM = _haversineMeters(_takeoffLat, _takeoffLon, _landingLat, _landingLon);

        var airtimeS = duration.toFloat() / 1000.0;

        // Encode the landing path as a numeric code so the _lastJump
        // dictionary contains only primitive numeric values. Real-watch
        // crashes after many jumps point to the mixed-type dictionary
        // (Number/Float/String/Boolean) created here; keeping the value
        // payload strictly numeric avoids the suspected runtime issue
        // while still letting downstream code map the code back to a
        // human-readable string.
        var landingPathCode = _landingPathToCode(_lastLandingPath);

        // Build _lastJump and emit the JUMP LANDED log. A previous
        // crash happened in this block, so we also keep the try/catch
        // as a second line of defence.
        try {
            _lastJump = {
                :durationMs      => duration,
                :heightM         => heightM,
                :lengthM         => lengthM.toFloat(),
                :airtimeS        => airtimeS,
                :startTs         => _jumpStartTs,
                :endTs           => when,
                :peakDeltaPa     => peakDelta,
                :peakTs          => _peakTs,
                :landingPathCode => landingPathCode
            };

            Logger.info(
                "JUMP LANDED ts=" + when
                + " durationMs=" + duration
                + " heightM=" + heightM
                + " airtimeS=" + airtimeS.format("%.2f")
                + " landingPath=" + _lastLandingPath
                + " landingPathCode=" + landingPathCode
                + " freefallConfirmed=" + (_freefallConfirmed ? "true" : "false")
                + " lengthM=" + lengthM
                + " peakPressureDeltaPa=" + peakDelta
                + " landingPressurePa=" + _landingPressure
            );
        } catch (e) {
            Logger.error("_enterLanding: failed to record jump e=" + e);
            // Minimal fallback so the session dump still has a row and
            // downstream consumers do not see null.
            _lastJump = {
                :durationMs      => duration,
                :heightM         => 0,
                :lengthM         => 0.0f,
                :airtimeS        => airtimeS,
                :startTs         => _jumpStartTs,
                :endTs           => when,
                :peakDeltaPa     => 0,
                :peakTs          => 0,
                :landingPathCode => landingPathCode
            };
        }
        _enterCoasting(when);
    }

    // Convert the internal string landing-path name into a small
    // numeric code. Downstream code (logs, session dump, review view)
    // maps the code back to a string. Keeping jump dictionaries free
    // of String values avoids the mixed-type dictionary crashes seen
    // on the real watch after many jumps.
    function _landingPathToCode(path as String) as Number {
        if (path.equals("pressure")) { return 0; }
        if (path.equals("gps"))      { return 1; }
        if (path.equals("lowG"))     { return 2; }
        if (path.equals("timeout"))  { return 3; }
        return -1;
    }

    function _enterCoasting(when as Number) as Void {
        _state = STATE_COASTING;
        _coastEndTs = when + COAST_MS;
        _aboveCount = 0;
        _belowCount = 0;
        Logger.info("detector: LANDING -> COASTING (rearm ts=" + _coastEndTs + ")");
    }

    // Great-circle distance between two lat/lon points, in metres.
    // Used purely to derive ground speed for landing corroboration.

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
