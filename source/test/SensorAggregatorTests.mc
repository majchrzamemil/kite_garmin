// SensorAggregatorTests
//
// Unit tests for source/SensorAggregator.mc. Verifies the ring-buffer
// behaviour for accelerometer, pressure, and GPS samples.
//
// Run in the Connect IQ simulator via:
//
//   monkeyc -o build/test.prg -d instinct2 -f monkey.jungle --unit-test
//   monkeydo build/test.prg instinct2 -t
//
// See docs/TESTING.md for the full workflow. The `(:test)` annotation
// marks each function so the Connect IQ compiler includes it in the
// unit-test build and `monkeydo -t` runs it.

import Toybox.Lang;
import Toybox.Test;

(:test)
function testAccelBuffer(logger as Test.Logger) as Boolean {
    var agg = new SensorAggregator();

    Test.assert(agg.getAccelCount() == 0);

    agg.pushAccel(1.0, 2.0, 3.0, 100);
    agg.pushAccel(4.0, 5.0, 6.0, 200);
    agg.pushAccel(7.0, 8.0, 9.0, 300);

    Test.assert(agg.getAccelCount() == 3);

    var latest = agg.getLatestAccel();
    Test.assert(latest != null);
    Test.assert(latest[:x] == 7.0);
    Test.assert(latest[:y] == 8.0);
    Test.assert(latest[:z] == 9.0);
    Test.assert(latest[:when] == 300);

    // Buffer should still report 3 (well under capacity).
    var recent = agg.getRecentAccel(10);
    Test.assert(recent.size() == 3);

    return true;
}

(:test)
function testPressureBuffer(logger as Test.Logger) as Boolean {
    var agg = new SensorAggregator();

    Test.assert(agg.getPressureCount() == 0);

    agg.pushPressure(101300, 100);
    agg.pushPressure(101275, 200);
    agg.pushPressure(101250, 300);

    Test.assert(agg.getPressureCount() == 3);

    var latest = agg.getLatestPressure();
    Test.assert(latest != null);
    Test.assert(latest[:pa] == 101250);
    Test.assert(latest[:when] == 300);

    return true;
}

(:test)
function testPositionBuffer(logger as Test.Logger) as Boolean {
    var agg = new SensorAggregator();

    Test.assert(agg.getPositionCount() == 0);

    agg.pushPosition(45.0 as Double, -73.0 as Double, 100);
    agg.pushPosition(45.0001 as Double, -73.0001 as Double, 200);
    agg.pushPosition(45.0002 as Double, -73.0002 as Double, 300);

    Test.assert(agg.getPositionCount() == 3);

    var latest = agg.getLatestPosition();
    Test.assert(latest != null);
    Test.assert(latest[:lat] == 45.0002 as Double);
    Test.assert(latest[:lon] == -73.0002 as Double);
    Test.assert(latest[:when] == 300);

    // Windowed accessor must return oldest-first chronological order.
    var recent = agg.getRecentPositions(2);
    Test.assert(recent.size() == 2);
    Test.assert(recent[0][:when] == 200);
    Test.assert(recent[1][:when] == 300);
    Test.assert(recent[0][:lat] == 45.0001 as Double);

    return true;
}

(:test)
function testRingOverwrite(logger as Test.Logger) as Boolean {
    var agg = new SensorAggregator();
    var cap = SensorAggregator.ACCEL_CAPACITY;

    // Push 2x capacity + 5 samples. The internal write counter climbs
    // past capacity, but the public count accessor must cap at capacity
    // and the latest sample must always be the most recently pushed.
    var total = (cap * 2) + 5;
    for (var i = 0; i < total; i++) {
        agg.pushAccel(i.toFloat(), 0.0, 0.0, i);
    }

    Test.assert(agg.getAccelCount() == cap);

    var latest = agg.getLatestAccel();
    Test.assert(latest != null);
    Test.assert(latest[:x] == (total - 1).toFloat());
    Test.assert(latest[:when] == total - 1);

    // Also exercise the pressure and GPS rings for completeness.
    var pTotal = (SensorAggregator.PRESSURE_CAPACITY * 2) + 3;
    for (var i = 0; i < pTotal; i++) {
        agg.pushPressure(100000 + i, i);
    }
    Test.assert(agg.getPressureCount() == SensorAggregator.PRESSURE_CAPACITY);

    var gTotal = (SensorAggregator.GPS_CAPACITY * 2) + 4;
    for (var i = 0; i < gTotal; i++) {
        agg.pushPosition((i.toDouble()) * 0.0001, 0.0 as Double, i);
    }
    Test.assert(agg.getPositionCount() == SensorAggregator.GPS_CAPACITY);

    return true;
}
