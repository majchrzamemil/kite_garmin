// App entrypoint for Kite Jump Tracker.
//
// This is the class listed as `entry="App"` in manifest.xml. Connect IQ
// instantiates it once on launch and drives its lifecycle through
// onStart / onStop / onSleep / onWake.
//
// Phase 2 wires up the sensor pipeline: accelerometer (polled via the
// legacy Toybox.Sensor.getInfo API at 40 Hz using a Timer, because
// registerSensorDataListener crashes on Connect IQ 6.0.2 devices such
// as the Instinct Solar 2), barometric pressure (read from the same
// Sensor.getInfo() snapshot — raw ambient pressure, not the MSL-
// compensated value returned by SensorHistory.getPressureHistory()),
// and GPS (via Position.enableLocationEvents). All three streams are
// pushed into a SensorAggregator with rolling buffers; the JumpDetector
// (phase 2 step 2) will read from that aggregator.
//
// Phase 3 swaps AppView for the session UI and adds FIT export.

import Toybox.Activity;
import Toybox.Application;
import Toybox.Graphics;
import Toybox.Lang;
import Toybox.Position;
import Toybox.Sensor;
import Toybox.System;
import Toybox.Timer;
import Toybox.WatchUi;

class App extends Application.AppBase {

    var _aggregator as SensorAggregator;
    var _detector as JumpDetector;
    var _accelTimer as Timer.Timer?;
    var _pressureTimer as Timer.Timer?;
    var _lastJumpEndTs as Number;
    var _sessionManager as SessionManager;
    var _inputDelegate as AppInputDelegate;
    var _sessionView as SessionView?;
    var _totalAirtimeMs as Number;
    var _pendingJump as Dictionary?;

    function initialize() {
        AppBase.initialize();
        _aggregator = new SensorAggregator();
        _detector = new JumpDetector(_aggregator);
        _accelTimer = null;
        _pressureTimer = null;
        _lastJumpEndTs = 0;
        _sessionManager = new SessionManager();
        _inputDelegate = new AppInputDelegate(self);
        _sessionView = null;
        _totalAirtimeMs = 0;
        _pendingJump = null;
        Logger.info("App.initialize: done");
    }

    // onStart fires once when the app launches. We do NOT start the
    // sensor pipeline here any more; sensors only run while a FIT
    // recording session is active. The actual pipeline start happens
    // in beginSession() when the user presses START.

    function onStart(state) {
        Logger.info("App.onStart: entered (session state=" + _sessionManager.getStateName() + ")");
        Logger.info("app ready (session state=" + _sessionManager.getStateName() + ")");
    }

    // onStop fires when the user exits the app. If a session is still
    // recording, close it (and therefore the FIT file) before tearing
    // down the sensor pipeline so we do not lose the activity.

    function onStop(state) {
        if (_sessionManager.isRecording()) {
            Logger.info("onStop: active session, stopping before pipeline teardown");
            _sessionManager.stopSession();
        }
        stopSensorPipeline();
    }

    // Return the initial view. Phase 1 just shows a label; phase 3 swaps
    // this for the session start screen.

    function getInitialView() {
        Logger.info("App.getInitialView: returning StartView");
        return [ new StartView(), new AppInputDelegate(self) ];
    }

    // ------------------------------------------------------------------
    // Sensor pipeline
    // ------------------------------------------------------------------

    function startSensorPipeline() as Void {
        Logger.info("pipeline: starting");

        // Accelerometer via the legacy Sensor.getInfo() / info.accel
        // path (API 1.0.0 / 2.0.0). Sensor.registerSensorDataListener
        // (API 2.3.0) crashes on Connect IQ 6.0.2 devices (e.g.
        // Instinct Solar 2) with "Symbol Not Found Error" on both
        // dictionary-style and member-style access of the returned
        // Sensor.SensorData. The accelerometer is granted by the
        // <uses-permission id="Sensor"/> entry in manifest.xml, so no
        // explicit enable call is needed; we just poll at 40 Hz via a
        // Timer.
        if (Toybox has :Sensor) {
            _accelTimer = new Timer.Timer();
            _accelTimer.start(method(:pollAccel), 25, true); // 40 Hz
            Logger.info("pipeline: accelerometer polling timer started");
        } else {
            Logger.warn("pipeline: Sensor module not available");
        }

        // Pressure is read via Activity.getActivityInfo() at 1 Hz from
        // a dedicated timer. SensorHistory.getPressureHistory() on the
        // Instinct Solar 2 returns GPS-altitude-compensated MSL
        // pressure, which stays nearly flat during a jump. Raw ambient
        // pressure from the barometer changes ~12 Pa per metre of
        // altitude, which is what the height calculation needs.
        _pressureTimer = new Timer.Timer();
        _pressureTimer.start(method(:pollPressure), 1000, true); // 1 Hz
        Logger.info("pipeline: pressure polling timer started");

        // GPS. LOCATION_CONTINUOUS keeps the receiver warm at ~1 Hz so
        // jump segments can be reconstructed between fixes.
        if (Toybox has :Position) {
            Position.enableLocationEvents(Position.LOCATION_CONTINUOUS, method(:onPosition));
            Logger.info("pipeline: GPS enabled (continuous)");
        } else {
            Logger.warn("pipeline: Position not available");
        }
    }

    function stopSensorPipeline() as Void {
        Logger.info("pipeline: stopping");

        if (_accelTimer != null) {
            _accelTimer.stop();
            _accelTimer = null;
        }

        if (_pressureTimer != null) {
            _pressureTimer.stop();
            _pressureTimer = null;
        }

        if (Toybox has :Position) {
            Position.enableLocationEvents(Position.LOCATION_DISABLE, null);
        }
    }

    // ------------------------------------------------------------------
    // Callbacks
    // ------------------------------------------------------------------

    function pollAccel() as Void {
        if (!(Toybox has :Sensor)) { return; }
        var info = Sensor.getInfo();
        if (info == null) { return; }

        // Pressure is read in pollPressure() at 1 Hz via the
        // Activity.getActivityInfo() dual API. Do not push pressure
        // from here; that would double-write the aggregator.

        // Accelerometer.
        if (info has :accel && info.accel != null) {
            var a = info.accel;
            if (a != null && a.size() >= 3) {
                var x = a[0].toFloat() * 9.80665 / 1000.0;
                var y = a[1].toFloat() * 9.80665 / 1000.0;
                var z = a[2].toFloat() * 9.80665 / 1000.0;
                var when = System.getTimer();
                _aggregator.pushAccel(x, y, z, when);
                _detector.onAccelSample(x, y, z, when);
                _checkForLandedJump();
            }
        }
    }

    function pollPressure() as Void {
        var rawPa = null;
        var filteredPa = null;
        if (Toybox has :Activity) {
            var info = Activity.getActivityInfo();
            if (info != null) {
                if (info has :rawAmbientPressure && info.rawAmbientPressure != null) {
                    rawPa = info.rawAmbientPressure;
                }
                if (info has :ambientPressure && info.ambientPressure != null) {
                    filteredPa = info.ambientPressure;
                }
            }
        }

        Logger.info("pressure: raw=" + (rawPa == null ? "null" : rawPa.toFloat().format("%.1f"))
            + " filtered=" + (filteredPa == null ? "null" : filteredPa.toFloat().format("%.1f")));

        if (rawPa != null) {
            _aggregator.pushPressure(rawPa.toNumber(), System.getTimer());
        }
        _detector.tick(System.getTimer());
    }

    function onPosition(info as Position.Info) as Void {
        Logger.info("App.onPosition: entered");
        if (info == null) {
            return;
        }
        var lat = info.position != null ? info.position.toDegrees()[0] : 0.0;
        var lon = info.position != null ? info.position.toDegrees()[1] : 0.0;
        var when = info.when != null ? info.when.value() : System.getTimer();
        _aggregator.pushPosition(lat, lon, when);
        Logger.info("position: lat=" + lat.format("%.6f") + " lon=" + lon.format("%.6f"));
    }

    function _checkForLandedJump() as Void {
        var jump = _detector.getLastJump();
        if (jump == null) {
            return;
        }
        Logger.info("App._checkForLandedJump: entered");
        Logger.info("App._checkForLandedJump: jump found");
        var endTs = jump[:endTs];
        if (endTs == null || endTs <= _lastJumpEndTs) {
            return;
        }
        _lastJumpEndTs = endTs;
        if (!_sessionManager.isRecording()) {
            Logger.info("ui: jump detected while idle endTs=" + endTs + " - not displayed");
            return;
        }
        Logger.info("App._checkForLandedJump: before addJumpLap");
        _sessionManager.addJumpLap(jump);
        Logger.info("App._checkForLandedJump: after addJumpLap");

        // Accumulate airtime for the DoneView summary.
        var duration = jump.get(:durationMs);
        if (duration == null) { duration = 0; }
        _totalAirtimeMs += duration.toNumber();

        // Refresh the SessionView jump counter if we are currently on it.
        var sv = _sessionView;
        if (sv != null) {
            Logger.info("App._checkForLandedJump: updating SessionView count");
            sv.setJumpCount(_sessionManager.getJumpCount());
            sv.requestUpdate();
        }

        // Defer the SummaryView push to the UI thread. onSensor runs
        // off the UI thread, so calling WatchUi.pushView here crashes
        // with "IQ!". Schedule a redraw and let SessionView.onUpdate
        // do the actual push on the UI thread via pushPendingSummaryView.
        Logger.info("App._checkForLandedJump: setting _pendingJump endTs=" + endTs);
        _pendingJump = jump;
        Logger.info("App._checkForLandedJump: before requestUpdate");
        WatchUi.requestUpdate();
        Logger.info("App._checkForLandedJump: after requestUpdate");
    }

    // Public method invoked from SessionView.onUpdate (UI thread).
    // If a jump landed while the sensor callback was running, this is
    // where the SummaryView is actually pushed.
    function pushPendingSummaryView() as Void {
        if (_pendingJump == null) {
            return;
        }
        var jump = _pendingJump;
        var endTs = jump[:endTs];
        var heightM = jump.get(:heightM);
        var lengthM = jump.get(:lengthM);
        var duration = jump.get(:durationMs);
        if (heightM  == null) { heightM  = 0; }
        if (lengthM  == null) { lengthM  = 0; }
        if (duration == null) { duration = 0; }
        Logger.info(
            "App.pushPendingSummaryView: entered"
            + " endTs=" + endTs
            + " heightM=" + heightM.toFloat().format("%.1f")
            + " lengthM=" + lengthM.toFloat().format("%.1f")
            + " durationMs=" + duration
        );
        Logger.info("App.pushPendingSummaryView: before pushView");
        WatchUi.pushView(new SummaryView(jump), null, WatchUi.SLIDE_IMMEDIATE);
        _pendingJump = null;
        Logger.info("App.pushPendingSummaryView: after pushView (pending cleared)");
    }

    // ------------------------------------------------------------------
    // Session control
    //
    // beginSession / endSession are called by the input delegate
    // (added in Chunk 2) when the user presses START / ENTER. Sensors
    // are gated on a live session so the accelerometer, pressure
    // timer, and GPS only run while we are actually writing a FIT file.
    // ------------------------------------------------------------------

    function beginSession() as Void {
        Logger.info("App.beginSession: entered (isRecording=" + _sessionManager.isRecording() + ")");
        Logger.info("beginSession: requested");
        if (!_sessionManager.startSession()) {
            Logger.warn("beginSession: startSession refused");
            return;
        }
        Logger.info("App.beginSession: startSession ok");
        // Reset running airtime accumulator for the new session.
        _totalAirtimeMs = 0;
        // Clear any leftover pending jump from a previous session.
        _pendingJump = null;
        // Switch to SessionView BEFORE starting sensors so the UI
        // thread has settled before accelerometer/GPS callbacks can
        // fire. This avoids the "IQ!" race observed in the field.
        _sessionView = new SessionView(_sessionManager, self);
        Logger.info("App.beginSession: before switchToView(SessionView)");
        WatchUi.switchToView(_sessionView, _inputDelegate, WatchUi.SLIDE_IMMEDIATE);
        Logger.info("App.beginSession: after switchToView");
        Logger.info("beginSession: switched to SessionView");
        Logger.info("App.beginSession: before startSensorPipeline");
        startSensorPipeline();
        Logger.info("App.beginSession: after startSensorPipeline");
    }

    function endSession() as Void {
        Logger.info("App.endSession: entered (isRecording=" + _sessionManager.isRecording() + ")");
        Logger.info("endSession: requested");
        Logger.info("App.endSession: before stopSensorPipeline");
        stopSensorPipeline();
        Logger.info("App.endSession: after stopSensorPipeline");
        var jumps = _sessionManager.getJumpCount();
        Logger.info("App.endSession: before stopSession (jumps=" + jumps + ")");
        if (!_sessionManager.stopSession()) {
            Logger.warn("endSession: stopSession refused");
            return;
        }
        Logger.info("App.endSession: after stopSession");
        _sessionView = null;
        _pendingJump = null;
        var airtimeS = (_totalAirtimeMs.toFloat()) / 1000.0;
        Logger.info("App.endSession: before switchToView(DoneView)");
        WatchUi.switchToView(
            new DoneView(jumps, airtimeS),
            _inputDelegate,
            WatchUi.SLIDE_IMMEDIATE
        );
        Logger.info("App.endSession: after switchToView");
        Logger.info("endSession: switched to DoneView (jumps=" + jumps + " airtimeS=" + airtimeS.format("%.2f") + ")");
    }

    function isRecording() as Boolean {
        var r = _sessionManager.isRecording();
        Logger.info("App.isRecording: returning " + r);
        return r;
    }
}

// The simplest possible Connect IQ view: paint a centered "Hello" string.
// Replaced in phase 3 by the session UI.

class AppView extends WatchUi.View {

    function initialize() {
        View.initialize();
    }

    function onUpdate(dc as Graphics.Dc) as Void {
        dc.setColor(Graphics.COLOR_BLACK, Graphics.COLOR_BLACK);
        dc.clear();

        dc.setColor(Graphics.COLOR_WHITE, Graphics.COLOR_TRANSPARENT);
        dc.drawText(
            dc.getWidth() / 2,
            dc.getHeight() / 2,
            Graphics.FONT_MEDIUM,
            "Kite Tracker",
            Graphics.TEXT_JUSTIFY_CENTER
        );
    }
}
