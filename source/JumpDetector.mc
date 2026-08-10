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
    // Takeoff threshold ~1.25 G (filters normal wrist motion during riding).
    static const TAKEOFF_G            = 1.25;
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
    // current reading is within this many Pa of the pre-jump baseline.
    // GPS speed in m/s below which we trust the rider is on the ground
    // (or at least not travelling under kite power).
    static const PRESSURE_RETURN_PA   = 50;
    static const GPS_SPEED_LOW_MPS    = 1.5;

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
    }

    // Returns the most recently completed jump metrics, or null if no
    // jump has landed yet this session. Dictionary keys:
    //   :durationMs   Number
    //   :heightM      Number   (barometric, ICAO on _minPressure)
    //   :heightAccelM Number   (parabolic from airtime: g*T^2/8)
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
                    _enterAirborne(when);
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
                if (_minPressure == 0) {
                    _minPressure = p[:pa];
                } else if (p[:pa] < _minPressure) {
                    _minPressure = p[:pa];
                    _peakTs = when;
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

            // Landing check (only if freefall confirmed)
            if (g < LANDING_G) {
                _belowCount++;
                if (_belowCount >= LANDING_SAMPLES && _freefallConfirmed) {
                    _maybeLand(when);
                }
            } else {
                _belowCount = 0;
            }
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
    // non-accelerometer tick) so the COASTING debounce can advance.

    function tick(when as Number) as Void {
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

    function _enterAirborne(when as Number) as Void {
        _state = STATE_AIRBORNE;
        _jumpStartTs = when;
        // Don't set _peakTs here — we don't know the peak timestamp yet.
        // The AIRBORNE branch updates _peakTs on every strict pressure drop.
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
        // Snapshot takeoff GPS coordinates for jump length.
        var pos = _aggregator.getLatestPosition();
        if (pos != null) {
            _takeoffLat = pos[:lat];
            _takeoffLon = pos[:lon];
        } else {
            _takeoffLat = 0.0;
            _takeoffLon = 0.0;
        }
        Logger.info("JUMP AIRBORNE ts=" + when);
        Logger.info("detector: ARMED -> AIRBORNE");
    }

    function _maybeLand(when as Number) as Void {
        var cur = _aggregator.getLatestPressure();

        // Pressure corroboration: current reading within PRESSURE_RETURN_PA
        // of the pre-jump baseline (absolute delta).
        var pressureOK = false;
        if (cur != null && _baselinePressure > 0) {
            var delta = cur[:pa] - _baselinePressure;
            if (delta < 0) { delta = -delta; }
            pressureOK = delta <= PRESSURE_RETURN_PA;
        }

        // GPS corroboration: ground speed from the last two fixes is low.
        var speedOK = false;
        var recent = _aggregator.getRecentPositions(2);
        if (recent.size() == 2) {
            var dt = (recent[1][:when] - recent[0][:when]).toFloat() / 1000.0;
            if (dt > 0.0) {
                var dist = _haversineMeters(
                    recent[0][:lat], recent[0][:lon],
                    recent[1][:lat], recent[1][:lon]
                );
                var speed = dist / dt;
                speedOK = speed < GPS_SPEED_LOW_MPS;
            }
        }

        if (pressureOK || speedOK) {
            if (cur != null) {
                _landingPressure = cur[:pa];
            } else {
                _landingPressure = 0;
            }
            _enterLanding(when);
        }
        // If neither corroborator fires yet, keep _belowCount where it
        // is and re-check on the next accel tick.
    }

    function _enterLanding(when as Number) as Void {
        _state = STATE_LANDING;
        Logger.info("detector: AIRBORNE -> LANDING");
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
            if (ratio > 0.0 && ratio < 1.0) {
                heightM = (44330.0 * (1.0 - Math.pow(ratio, 0.190263))).toFloat();
            }
        }

        // Length from Haversine of takeoff-to-landing positions.
        var lengthM = _haversineMeters(_takeoffLat, _takeoffLon, _landingLat, _landingLon);

        // Height from accelerometer-derived parabolic estimate.
        // Split the flight into ascent and descent phases using the
        // timestamp of the pressure minimum (peak altitude). For each
        // phase, h = g * t^2 / 2 (constant gravity, zero velocity at
        // the peak). Average the two heights: this is independent of
        // the (unknown) initial takeoff velocity.
        var heightAccelM = 0;
        if (_peakTs > 0 && _jumpStartTs > 0 && _peakTs > _jumpStartTs && when > _peakTs) {
            var tAscentS  = (_peakTs - _jumpStartTs).toFloat() / 1000.0;
            var tDescentS = (when - _peakTs).toFloat() / 1000.0;
            var hAscent  = G_MS2 * tAscentS  * tAscentS  / 2.0;
            var hDescent = G_MS2 * tDescentS * tDescentS / 2.0;
            heightAccelM = ((hAscent + hDescent) / 2.0).toFloat();
            Logger.info(
                "accel: tAscentS=" + tAscentS.format("%.2f")
                + " tDescentS=" + tDescentS.format("%.2f")
                + " hAscent=" + hAscent.format("%.2f")
                + " hDescent=" + hDescent.format("%.2f")
                + " hAccel=" + heightAccelM.toFloat().format("%.2f")
            );
        }

        var airtimeS = duration.toFloat() / 1000.0;

        _lastJump = {
            :durationMs   => duration,
            :heightM      => heightM,
            :heightAccelM => heightAccelM,
            :lengthM      => lengthM.toFloat(),
            :airtimeS     => airtimeS,
            :startTs      => _jumpStartTs,
            :endTs        => when,
            :peakDeltaPa  => peakDelta,
            :peakTs       => _peakTs
        };

        Logger.info(
            "JUMP LANDED ts=" + when
            + " durationMs=" + duration
            + " heightM=" + heightM
            + " heightAccelM=" + heightAccelM
            + " airtimeS=" + airtimeS.format("%.2f")
            + " freefallConfirmed=true"
            + " lengthM=" + lengthM
            + " peakPressureDeltaPa=" + peakDelta
            + " landingPressurePa=" + _landingPressure
        );
        _enterCoasting(when);
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
