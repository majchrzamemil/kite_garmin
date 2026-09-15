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
import Toybox.Math;
import Toybox.Position;
import Toybox.Sensor;
import Toybox.System;
import Toybox.Time;
import Toybox.Timer;
import Toybox.WatchUi;

class App extends Application.AppBase {

    // Requested accelerometer sample rate, clamped to the device maximum
    // at registration time. 25 Hz is what every JumpDetector threshold
    // is written against.
    static const ACCEL_RATE_HZ = 25;

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
    var _sessionJumps as Array<Dictionary>;
    var _sessionStartMs as Number;

    // Accelerometer feed. _accelPath records which of the two paths is
    // live so the session dump can say so; see startSensorPipeline.
    var _accelRateHz as Number;
    var _accelPath as String;

    // Per-session sensor statistics, emitted as one line each at session
    // end. The 2026-09-14 session recorded 0 jumps and the log could not
    // say why: the only clue was minG=1.09 on three discards. These two
    // lines survive APP.TXT rotation and answer "is the feed real?".
    var _gCount as Number;
    var _gMin as Float;
    var _gMax as Float;
    var _gBelow100 as Number;
    var _gBelow090 as Number;
    var _paCount as Number;
    var _paMin as Number;
    var _paMax as Number;
    var _paMaxStep as Number;
    var _paLast as Number;

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
        _sessionJumps = [] as Array<Dictionary>;
        _sessionStartMs = 0;
        _accelRateHz = ACCEL_RATE_HZ;
        _accelPath = "none";
        // Assigned here as well as in _resetSensorStats because the type
        // checker only tracks initialization done directly in the
        // constructor. _resetSensorStats owns the real values.
        _gCount = 0;
        _gMin = 0.0f;
        _gMax = 0.0f;
        _gBelow100 = 0;
        _gBelow090 = 0;
        _paCount = 0;
        _paMin = 0;
        _paMax = 0;
        _paMaxStep = 0;
        _paLast = 0;
        _resetSensorStats();
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

        // Accelerometer via the streaming API. Sensor.getInfo().accel is
        // a snapshot refreshed on the sensor's own cadence (~1 Hz on this
        // hardware), so polling it at 40 Hz just re-reads one value: the
        // 2026-09-14 session saw three >=1.8 G triggers in 44 minutes and
        // a window minimum that never fell below 1.09 G. The streaming
        // listener delivers real per-sample batches.
        //
        // registerSensorDataListener was previously believed to crash on
        // Connect IQ 6.0.2, but both recorded crashes were our own misuse
        // (dictionary access instead of .accelerometerData, and treating
        // the batched x/y/z arrays as scalars). Both are handled in
        // onSensorData; the poll path stays as a fallback in case there
        // is a third cause.
        if (Toybox has :Sensor) {
            _startAccelStream();
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

        if (Toybox has :Sensor) {
            try {
                Sensor.unregisterSensorDataListener();
            } catch (e) {
                Logger.warn("pipeline: unregisterSensorDataListener e=" + e);
            }
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

    // Register the streaming accelerometer listener. Falls back to the
    // legacy 40 Hz getInfo() poll if registration throws, so a failure
    // here degrades the session instead of ending it.

    function _startAccelStream() as Void {
        var rate = ACCEL_RATE_HZ;
        if (Sensor has :getMaxSampleRate) {
            var maxRate = Sensor.getMaxSampleRate();
            if (maxRate != null && maxRate > 0 && maxRate < rate) {
                rate = maxRate;
            }
        }
        _accelRateHz = rate;

        try {
            Sensor.registerSensorDataListener(
                method(:onSensorData),
                {
                    :period => 1,
                    :accelerometer => { :enabled => true, :sampleRate => rate }
                }
            );
            _accelPath = "stream";
            Logger.info("pipeline: accel=stream rateHz=" + rate);
        } catch (e) {
            Logger.error("pipeline: accel stream failed, falling back e=" + e);
            _accelTimer = new Timer.Timer();
            _accelTimer.start(method(:pollAccel), 25, true); // 40 Hz
            _accelPath = "poll";
            Logger.info("pipeline: accel=poll");
        }
    }

    // Streaming accelerometer callback. One batch per :period second.
    //
    // Two rules here are load-bearing, both learned from crashes:
    // accelerometerData is a member, not a dictionary key; and x/y/z are
    // Array<Number> of milli-G, not scalars. Nothing logs inside the
    // loop - the recorded OOM came from string building on this path.

    function onSensorData(data as Sensor.SensorData) as Void {
        if (data == null) { return; }

        var accel = null;
        try {
            accel = data.accelerometerData;
        } catch (e) {
            Logger.error("onSensorData: accelerometerData unavailable e=" + e);
            return;
        }
        if (accel == null) { return; }

        var xs = accel.x;
        var ys = accel.y;
        var zs = accel.z;
        if (xs == null || ys == null || zs == null) { return; }

        var n = xs.size();
        if (n == 0 || ys.size() < n || zs.size() < n) { return; }

        var now = System.getTimer();
        for (var i = 0; i < n; i++) {
            var when = batchSampleTime(now, n, i, _accelRateHz);
            var x = xs[i].toFloat() * 9.80665 / 1000.0;
            var y = ys[i].toFloat() * 9.80665 / 1000.0;
            var z = zs[i].toFloat() * 9.80665 / 1000.0;
            _aggregator.pushAccel(x, y, z, when);
            _detector.onAccelSample(x, y, z, when);
            _accumAccelStats(x, y, z);
        }

        // Once per batch, not once per sample: COAST_MS (1500 ms) is
        // longer than the 1 s batch, so at most one jump can complete
        // per callback.
        _checkForLandedJump();
    }

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
                _accumAccelStats(x, y, z);
                _checkForLandedJump();
            }
        }
    }

    function pollPressure() as Void {
        var rawPa = null;
        if (Toybox has :Activity) {
            var info = Activity.getActivityInfo();
            if (info != null) {
                if (info has :rawAmbientPressure && info.rawAmbientPressure != null) {
                    rawPa = info.rawAmbientPressure;
                }
            }
        }

        // NOTE: the raw/filtered pressure values are deliberately NOT
        // logged per sample. The on-device APP.TXT log rotates at only
        // a few KB, and 1 Hz sensor lines rotated away every interesting
        // detector line during the 2026-09-11 test session. Per-event
        // values (baseline/dip/drift) are carried by the detector's
        // JUMP CANDIDATE / discard / LANDED lines instead.

        if (rawPa != null) {
            var pa = rawPa.toNumber();
            _aggregator.pushPressure(pa, System.getTimer());
            _accumBaroStats(pa);
        }
        _detector.tick(System.getTimer());
    }

    function onPosition(info as Position.Info) as Void {
        if (info == null) {
            return;
        }
        var lat = info.position != null ? info.position.toDegrees()[0] : 0.0;
        var lon = info.position != null ? info.position.toDegrees()[1] : 0.0;
        // Stamp the fix with System.getTimer() (the same clock the
        // detector and accelerometer samples use), NOT the GPS
        // Time.Moment. Mixing the two clocks made every position
        // timestamp incomparable with jump timestamps, so jump length
        // always computed to 0 (2026-09-11 session: lengthM=0.00 on
        // every jump).
        _aggregator.pushPosition(lat, lon, System.getTimer());
    }

    // --- Per-session sensor statistics -------------------------------

    function _resetSensorStats() as Void {
        _gCount     = 0;
        _gMin       = 99.0f;
        _gMax       = 0.0f;
        _gBelow100  = 0;
        _gBelow090  = 0;
        _paCount    = 0;
        _paMin      = 0;
        _paMax      = 0;
        _paMaxStep  = 0;
        _paLast     = 0;
    }

    function _accumAccelStats(x as Float, y as Float, z as Float) as Void {
        var g = Math.sqrt(x * x + y * y + z * z) / 9.80665;
        _gCount++;
        if (g < _gMin) { _gMin = g; }
        if (g > _gMax) { _gMax = g; }
        if (g < 1.00) { _gBelow100++; }
        if (g < 0.90) { _gBelow090++; }
    }

    function _accumBaroStats(pa as Number) as Void {
        if (_paCount == 0) {
            _paMin = pa;
            _paMax = pa;
        } else {
            if (pa < _paMin) { _paMin = pa; }
            if (pa > _paMax) { _paMax = pa; }
            var step = pa - _paLast;
            if (step < 0) { step = -step; }
            if (step > _paMaxStep) { _paMaxStep = step; }
        }
        _paLast = pa;
        _paCount++;
    }

    function _checkForLandedJump() as Void {
        var jump = _detector.getLastJump();
        if (jump == null) {
            return;
        }
        var endTs = jump[:endTs];
        if (endTs == null || endTs <= _lastJumpEndTs) {
            // Already-seen (or already-consumed) jump. This runs at the
            // 40 Hz accel rate - logging here would flood the tiny
            // on-device log and rotate the useful lines away.
            return;
        }
        _lastJumpEndTs = endTs;
        Logger.info("App._checkForLandedJump: new jump endTs=" + endTs);
        if (!_sessionManager.isRecording()) {
            Logger.info("ui: jump detected while idle endTs=" + endTs + " - not displayed");
            return;
        }
        Logger.info("App._checkForLandedJump: before addJumpLap");
        // Track the jump for the session-end dump BEFORE writing the FIT
        // lap. The detector creates a fresh Dictionary per landing, and
        // addJumpLap runs synchronously here, but stopSession() can race
        // ahead on the UI thread and save the FIT file before this
        // callback finishes adding to _sessionJumps. Adding first ensures
        // the in-app review/dump can never lag behind the FIT file.
        _sessionJumps.add(jump);

        var recorded = _sessionManager.addJumpLap(jump);
        Logger.info("App._checkForLandedJump: after addJumpLap (recorded=" + recorded + ")");
        jump[:recorded] = recorded;

        if (!recorded) {
            // SessionManager filtered this jump (e.g. baro heightM <= 1.5m
            // threshold). It stays in _sessionJumps with :recorded=false
            // for diagnostic dumps; SessionReviewView filters it out.
            // Skip per-jump UI bookkeeping and never push SummaryView.
            Logger.info("ui: jump filtered (heightM=" + jump[:heightM] + "m), not showing popup");
            return;
        }

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
        // Reset the session-scoped jump log and stamp the start time.
        // The list is cleared here (not just at endSession) so a
        // begin/abort/abort/begin cycle never accumulates stale jumps.
        _sessionJumps = [] as Array<Dictionary>;
        _sessionStartMs = System.getTimer();
        _resetSensorStats();
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
        // Dump the full session log block (and write the storage
        // backup) before switching to DoneView so the user sees the
        // summary while the log is already on disk.
        Logger.info("App.endSession: before _dumpSession");
        _dumpSession();
        Logger.info("App.endSession: after _dumpSession");
        Logger.info("App.endSession: before switchToView(SessionReviewView)");
        var reviewView = new SessionReviewView(_sessionJumps, airtimeS, jumps);
        WatchUi.switchToView(
            reviewView,
            new SessionReviewInputDelegate(reviewView),
            WatchUi.SLIDE_IMMEDIATE
        );
        Logger.info("App.endSession: after switchToView");
        Logger.info("endSession: switched to SessionReviewView (jumps=" + jumps + " airtimeS=" + airtimeS.format("%.2f") + ")");
    }

    function isRecording() as Boolean {
        var r = _sessionManager.isRecording();
        Logger.info("App.isRecording: returning " + r);
        return r;
    }

    // ------------------------------------------------------------------
    // _dumpSession
    //
    // Emits a contiguous [KITE] SESSION_DUMP_START ... SESSION_DUMP_END
    // block to the log so every jump detected during the session can
    // be copied out of GARMIN/Apps/LOGS/APP.TXT and parsed offline.
    //
    // The log is the single source of truth for per-jump detail.
    // ------------------------------------------------------------------

    function _dumpSession() as Void {
        Logger.info("App._dumpSession: entered (jumpCount=" + _sessionJumps.size() + ")");

        // Wall-clock seconds for the dump header. Use Time.now().value()
        // (seconds since 1970) so a downstream reader can correlate the
        // log with calendar time.
        var wallClockS = 0;
        if (Toybox has :Time) {
            var now = Time.now();
            if (now != null) {
                wallClockS = now.value();
            }
        }

        var sessionDurationMs = 0;
        if (_sessionStartMs > 0) {
            var nowMs = System.getTimer();
            if (nowMs >= _sessionStartMs) {
                sessionDurationMs = nowMs - _sessionStartMs;
            }
        }

        // Record the detector's final state at end of session. If we
        // ended while still AIRBORNE the jump was never closed (no
        // landing path fired, possibly within the 30 s safety window);
        // this line makes that visible in the log without having to
        // scroll through JUMP AIRBORNE entries.
        Logger.info(
            "App._dumpSession: stateAtEnd=" + _detector.getStateName()
            + " recordedJumps=" + _sessionManager.getJumpCount()
        );

        Logger.info(
            "SESSION_DUMP_START"
            + " id=" + _sessionStartMs
            + " wallClockS=" + wallClockS
            + " jumpCount=" + _sessionJumps.size()
        );

        var recordedCount = 0;
        var totalAirtimeMs = 0;

        var i = 0;
        while (i < _sessionJumps.size()) {
            var j = _sessionJumps[i];

            // Look up each field defensively so a half-populated jump
            // (e.g. GPS never fixed, so lengthM is 0) still produces
            // a valid dump line.
            var startTs      = j.get(:startTs);
            var endTs        = j.get(:endTs);
            var durationMs   = j.get(:durationMs);
            var heightM      = j.get(:heightM);
            var lengthM      = j.get(:lengthM);
            var airtimeS     = j.get(:airtimeS);
            var peakDeltaPa      = j.get(:peakDeltaPa);
            var recorded         = j.get(:recorded);
            var landingPathCode  = j.get(:landingPathCode);
            if (startTs          == null) { startTs          = 0; }
            if (endTs            == null) { endTs            = 0; }
            if (durationMs       == null) { durationMs       = 0; }
            if (heightM          == null) { heightM          = 0; }
            if (lengthM          == null) { lengthM          = 0; }
            if (airtimeS         == null) { airtimeS         = 0.0f; }
            if (peakDeltaPa      == null) { peakDeltaPa      = 0; }
            if (recorded         == null) { recorded         = false; }
            if (landingPathCode  == null) { landingPathCode  = -1; }

            // The dictionary stores the landing path as a numeric code
            // (see JumpDetector._landingPathToCode). Translate back to a
            // human-readable string for the log line. Keep this mapping
            // identical to the one in SessionReviewView so the two
            // surfaces always show the same label. Dictionary.get()
            // returns Lang.Object?, so we compare via .equals() rather
            // than treating the value as a Number directly.
            var landingPath = _codeToLandingPath(
                landingPathCode.equals(0) ? 0 :
                landingPathCode.equals(1) ? 1 :
                landingPathCode.equals(2) ? 2 :
                landingPathCode.equals(3) ? 3 : -1
            );

            var isRecorded = false;
            if (recorded) { isRecorded = true; }
            if (isRecorded) {
                recordedCount++;
            }
            // Sum airtime from the raw duration so we are immune to
            // any rounding in airtimeS.
            totalAirtimeMs += durationMs.toNumber();

            // recorded is a Boolean; render it as a 1/0 numeric token
            // for the log so the line stays strictly numeric except for
            // the human-readable landingPath label.
            var recordedNum = isRecorded ? 1 : 0;

            Logger.info(
                "JUMP_DUMP"
                + " idx=" + i
                + " startTs=" + startTs
                + " endTs=" + endTs
                + " durationMs=" + durationMs
                + " heightM=" + heightM.toFloat().format("%.2f")
                + " lengthM=" + lengthM.toFloat().format("%.2f")
                + " airtimeS=" + airtimeS.toFloat().format("%.2f")
                + " peakDeltaPa=" + peakDeltaPa.toFloat().format("%.1f")
                + " landingPath=" + landingPath
                + " landingPathCode=" + landingPathCode
                + " recorded=" + recordedNum
            );
            i++;
        }

        var totalAirtimeS = totalAirtimeMs.toFloat() / 1000.0;

        // Sensor-health lines. One each per session so they survive the
        // APP.TXT rotation that erases per-event logging. ACCEL_STATS
        // answers "is the accelerometer feed real?" (n should be
        // rateHz x session seconds, and below090 must be non-zero on any
        // session with real movement). BARO_STATS answers "is the
        // pressure port usable?" - the 2026-09-14 FIT showed altitude
        // steps above 50 m between consecutive records.
        Logger.info(
            "ACCEL_STATS"
            + " path=" + _accelPath
            + " n=" + _gCount
            + " rateHz=" + _accelRateHz
            + " minG=" + (_gCount > 0 ? _gMin.format("%.2f") : "n/a")
            + " maxG=" + _gMax.format("%.2f")
            + " below100=" + _gBelow100
            + " below090=" + _gBelow090
        );
        Logger.info(
            "BARO_STATS"
            + " n=" + _paCount
            + " minPa=" + _paMin
            + " maxPa=" + _paMax
            + " maxStepPa=" + _paMaxStep
        );

        Logger.info(
            "SESSION_DUMP_END"
            + " totalJumps=" + _sessionJumps.size()
            + " recordedJumps=" + recordedCount
            + " totalAirtimeS=" + totalAirtimeS.format("%.2f")
            + " sessionDurationMs=" + sessionDurationMs
        );
    }
}

// Timestamp for sample i of an n-sample accelerometer batch that
// finished at nowMs. Stamping every sample in a batch with one instant
// would collapse the windows the detector walks backwards through, so
// the batch is spread backwards at the sample interval.

function batchSampleTime(nowMs as Number, n as Number, i as Number,
                         rateHz as Number) as Number {
    if (rateHz <= 0) { return nowMs; }
    return nowMs - ((n - 1 - i) * 1000) / rateHz;
}

// Translate a JumpDetector landing-path code back to a human-readable
// string for logging and on-screen display. Must stay in lock-step
// with JumpDetector: 0="impact" (the landing-first redesign has a
// single detection path), anything else = "unknown".
function _codeToLandingPath(code as Number) as String {
    if (code == 0) { return "impact"; }
    return "unknown";
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
