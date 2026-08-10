// SensorAggregator
//
// Phase 2 sensor pipeline buffer. Holds the latest rolling windows of
// accelerometer, barometric pressure, and GPS samples so the
// JumpDetector (phase 2 step 2) can inspect history without holding onto
// raw sensor callbacks.
//
// Buffer sizes are tuned for the Instinct Solar 2:
//
//   accel    : 100 samples  ≈ 4 s @ 25 Hz (matches accelerometer sample rate)
//   pressure :  64 samples  ≈ 32 s @ 2 Hz (we poll getPressureHistory every
//                                       1 s and the device typically returns
//                                       the last 2 samples per call)
//   gps      :  32 samples  ≈ 32 s @ 1 Hz (continuous GPS, 1 Hz update)
//
// Each buffer is implemented as a fixed-capacity ring with a monotonic
// write count. Reads walk backwards from the newest sample and unwrap the
// index modulo capacity. Once the buffer is full, the oldest sample is
// silently overwritten.
//
// All public mutators are void / O(1). Readers can either grab the
// newest sample or pull the last N samples for windowed analysis.

import Toybox.Lang;

class SensorAggregator {

    static const ACCEL_CAPACITY    = 100;
    static const PRESSURE_CAPACITY = 64;
    static const GPS_CAPACITY      = 32;

    // --- Accelerometer ring ---
    var _accelX    as Array<Float>;
    var _accelY    as Array<Float>;
    var _accelZ    as Array<Float>;
    var _accelWhen as Array<Number>;
    var _accelCount as Number;

    // --- Pressure ring ---
    var _pressure    as Array<Number>;
    var _pressureWhen as Array<Number>;
    var _pressureCount as Number;

    // --- GPS ring ---
    var _posLat  as Array<Double>;
    var _posLon  as Array<Double>;
    var _posWhen as Array<Number>;
    var _posCount as Number;

    function initialize() {
        _accelX        = new Array<Float>[ACCEL_CAPACITY];
        _accelY        = new Array<Float>[ACCEL_CAPACITY];
        _accelZ        = new Array<Float>[ACCEL_CAPACITY];
        _accelWhen     = new Array<Number>[ACCEL_CAPACITY];
        _accelCount    = 0;

        _pressure      = new Array<Number>[PRESSURE_CAPACITY];
        _pressureWhen  = new Array<Number>[PRESSURE_CAPACITY];
        _pressureCount = 0;

        _posLat        = new Array<Double>[GPS_CAPACITY];
        _posLon        = new Array<Double>[GPS_CAPACITY];
        _posWhen       = new Array<Number>[GPS_CAPACITY];
        _posCount      = 0;
    }

    // -- Mutators ------------------------------------------------------

    function pushAccel(x as Float, y as Float, z as Float, when as Number) as Void {
        var idx = _accelCount % ACCEL_CAPACITY;
        _accelX[idx]    = x;
        _accelY[idx]    = y;
        _accelZ[idx]    = z;
        _accelWhen[idx] = when;
        _accelCount++;
    }

    function pushPressure(pa as Number, when as Number) as Void {
        var idx = _pressureCount % PRESSURE_CAPACITY;
        _pressure[idx]    = pa;
        _pressureWhen[idx] = when;
        _pressureCount++;
    }

    function pushPosition(lat as Double, lon as Double, when as Number) as Void {
        var idx = _posCount % GPS_CAPACITY;
        _posLat[idx]  = lat;
        _posLon[idx]  = lon;
        _posWhen[idx] = when;
        _posCount++;
    }

    function reset() as Void {
        _accelCount    = 0;
        _pressureCount = 0;
        _posCount      = 0;
    }

    // -- Snapshot accessors --------------------------------------------

    function getAccelCount() as Number {
        return _accelCount < ACCEL_CAPACITY ? _accelCount : ACCEL_CAPACITY;
    }

    function getPressureCount() as Number {
        return _pressureCount < PRESSURE_CAPACITY ? _pressureCount : PRESSURE_CAPACITY;
    }

    function getPositionCount() as Number {
        return _posCount < GPS_CAPACITY ? _posCount : GPS_CAPACITY;
    }

    function getLatestAccel() as Dictionary? {
        if (_accelCount == 0) { return null; }
        var idx = (_accelCount - 1) % ACCEL_CAPACITY;
        return {
            :x    => _accelX[idx],
            :y    => _accelY[idx],
            :z    => _accelZ[idx],
            :when => _accelWhen[idx]
        };
    }

    function getLatestPressure() as Dictionary? {
        if (_pressureCount == 0) { return null; }
        var idx = (_pressureCount - 1) % PRESSURE_CAPACITY;
        return { :pa => _pressure[idx], :when => _pressureWhen[idx] };
    }

    function getLatestPosition() as Dictionary? {
        if (_posCount == 0) { return null; }
        var idx = (_posCount - 1) % GPS_CAPACITY;
        return {
            :lat  => _posLat[idx],
            :lon  => _posLon[idx],
            :when => _posWhen[idx]
        };
    }

    // -- Windowed accessors --------------------------------------------
    //
    // These return the last `maxSamples` of each buffer in chronological
    // (oldest-first) order. JumpDetector uses them for threshold checks
    // like "average vertical accel over the last 1.5 s" without doing
    // any buffer arithmetic itself.

    function getRecentAccel(maxSamples as Number) as Array<Dictionary> {
        return _copyAccelWindow(getAccelCount(), maxSamples);
    }

    function getRecentAccelSince(newestWhen as Number) as Array<Dictionary> {
        var avail = getAccelCount();
        var n = 0;
        // walk backwards from newest, count while within window
        for (var i = 0; i < avail; i++) {
            var idx = (_accelCount - 1 - i) % ACCEL_CAPACITY;
            if (_accelWhen[idx] < newestWhen) { break; }
            n++;
        }
        return _copyAccelWindow(n, n);
    }

    function getRecentPressure(maxSamples as Number) as Array<Dictionary> {
        var avail = getPressureCount();
        var n = maxSamples;
        if (n > avail) { n = avail; }
        var out = new Array<Dictionary>[n];
        var start = _pressureCount - n;
        for (var i = 0; i < n; i++) {
            var idx = (start + i) % PRESSURE_CAPACITY;
            out[i] = { :pa => _pressure[idx], :when => _pressureWhen[idx] };
        }
        return out;
    }

    function getRecentPositions(maxSamples as Number) as Array<Dictionary> {
        var avail = getPositionCount();
        var n = maxSamples;
        if (n > avail) { n = avail; }
        var out = new Array<Dictionary>[n];
        var start = _posCount - n;
        for (var i = 0; i < n; i++) {
            var idx = (start + i) % GPS_CAPACITY;
            out[i] = {
                :lat  => _posLat[idx],
                :lon  => _posLon[idx],
                :when => _posWhen[idx]
            };
        }
        return out;
    }

    function _copyAccelWindow(avail as Number, maxSamples as Number) as Array<Dictionary> {
        var n = maxSamples;
        if (n > avail) { n = avail; }
        var out = new Array<Dictionary>[n];
        var start = _accelCount - n;
        for (var i = 0; i < n; i++) {
            var idx = (start + i) % ACCEL_CAPACITY;
            out[i] = {
                :x    => _accelX[idx],
                :y    => _accelY[idx],
                :z    => _accelZ[idx],
                :when => _accelWhen[idx]
            };
        }
        return out;
    }
}
