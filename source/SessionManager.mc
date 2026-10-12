// SessionManager
//
// Phase 3 step 1. Owns the ActivityRecording.Session lifecycle for
// Kite Tracker so the rest of the app does not have to know about
// FIT or the ActivityRecording API. The App delegates start, stop,
// and per-jump lap work to this class and just asks whether we are
// currently recording.
//
// State machine
//   IDLE      - no session is open. startSession() may be called.
//   STARTING  - createSession() / createField() / start() in flight.
//   RECORDING - session.start() succeeded; addJumpLap() is allowed.
//   STOPPING  - session.stop() / save() in flight.
//   SAVED     - session is on disk. startSession() may be called
//               again to begin a fresh recording.
//
// All transitions and errors are logged with the [KITE] prefix via
// the project-wide Logger.

import Toybox.ActivityRecording;
import Toybox.FitContributor;
import Toybox.Lang;

class SessionManager {

    // States
    static const STATE_IDLE      = 0;
    static const STATE_STARTING  = 1;
    static const STATE_RECORDING = 2;
    static const STATE_STOPPING  = 3;
    static const STATE_SAVED     = 4;

    // FIT field IDs. Must match the ids declared in
    // resources/fitcontributions/fitcontributions.xml (Chunk 3).
    static const FIELD_HEIGHT       = 0;
    static const FIELD_LENGTH       = 1;
    static const FIELD_AIRTIME      = 2;
    // Record-level telemetry fields (ids 3/4): raw barometer and total-G
    // land in the FIT so false jumps can be replayed offline. The FIT
    // survives APP.TXT rotation; the text log does not.
    static const FIELD_PRESSURE     = 3;
    static const FIELD_ACCEL_G      = 4;

    var _state        as Number;
    var _session      as ActivityRecording.Session?;
    var _heightField  as FitContributor.Field?;
    var _lengthField  as FitContributor.Field?;
    var _airtimeField as FitContributor.Field?;
    var _pressureField as FitContributor.Field?;
    var _accelGField  as FitContributor.Field?;
    var _jumpCount    as Number;
    // Jumps the recorder itself refused (corrupt height). Reported on
    // the session-end DISCARD_TALLY line so a detector rejection and a
    // recorder rejection are distinguishable without a per-jump log.
    var _skippedSanity    as Number;

    function initialize() {
        _state        = STATE_IDLE;
        _session      = null;
        _heightField  = null;
        _lengthField  = null;
        _airtimeField = null;
        _pressureField = null;
        _accelGField  = null;
        _jumpCount    = 0;
        _skippedSanity    = 0;
    }

    function getState() as Number {
        return _state;
    }

    function getStateName() as String {
        if (_state == STATE_IDLE)      { return "IDLE"; }
        if (_state == STATE_STARTING)  { return "STARTING"; }
        if (_state == STATE_RECORDING) { return "RECORDING"; }
        if (_state == STATE_STOPPING)  { return "STOPPING"; }
        if (_state == STATE_SAVED)     { return "SAVED"; }
        return "UNKNOWN";
    }

    function isRecording() as Boolean {
        return _state == STATE_RECORDING;
    }

    function getJumpCount() as Number {
        return _jumpCount;
    }

    function getSkippedSanity() as Number {
        return _skippedSanity;
    }

    // ------------------------------------------------------------------
    // startSession
    //
    // Creates a new ActivityRecording.Session, registers three custom
    // lap fields (jump height / length / airtime) and starts the
    // session. Returns true on success; on any failure the manager
    // rolls back to STATE_IDLE so the caller may retry.
    // ------------------------------------------------------------------

    function startSession() as Boolean {
        Logger.info("SessionManager.startSession: entered (state=" + getStateName() + ")");
        if (_state != STATE_IDLE && _state != STATE_SAVED) {
            Logger.warn("startSession: rejected, current state=" + getStateName());
            return false;
        }

        Logger.info("session: " + getStateName() + " -> STARTING");
        _state = STATE_STARTING;

        // Pick the best available sport constant. SPORT_KITESURFING
        // was added in API 3.0.10; the project targets minApiLevel
        // 3.0.0 so we must guard the symbol at runtime.
        var sport = Activity.SPORT_GENERIC;
        if (Toybox.Activity has :SPORT_KITESURFING) {
            sport = Activity.SPORT_KITESURFING;
        } else {
            Logger.warn("session: SPORT_KITESURFING unavailable, using SPORT_GENERIC");
        }

        Logger.info("SessionManager.startSession: before createSession");
        var session = ActivityRecording.createSession({
            :name     => "Kite Tracker",
            :sport    => sport,
            :subSport => Activity.SUB_SPORT_GENERIC
        });
        Logger.info("SessionManager.startSession: after createSession");
        if (session == null) {
            _state = STATE_IDLE;
            Logger.error("session: createSession returned null");
            return false;
        }

        // Custom lap fields must be created before session.start() so
        // they are part of the FIT file from lap zero onward.
        Logger.info("SessionManager.startSession: before createField(height)");
        var hField = session.createField(
            "jump_height",
            FIELD_HEIGHT,
            FitContributor.DATA_TYPE_FLOAT,
            { :mesgType => FitContributor.MESG_TYPE_LAP, :units => "m" }
        );
        Logger.info("SessionManager.startSession: before createField(length)");
        var lField = session.createField(
            "jump_length",
            FIELD_LENGTH,
            FitContributor.DATA_TYPE_FLOAT,
            { :mesgType => FitContributor.MESG_TYPE_LAP, :units => "m" }
        );
        Logger.info("SessionManager.startSession: before createField(airtime)");
        var aField = session.createField(
            "jump_airtime",
            FIELD_AIRTIME,
            FitContributor.DATA_TYPE_FLOAT,
            { :mesgType => FitContributor.MESG_TYPE_LAP, :units => "s" }
        );
        // Record-level telemetry (optional: a failure here must not
        // cost the session, the lap fields above are the product).
        Logger.info("SessionManager.startSession: before createField(pressure)");
        _pressureField = session.createField(
            "raw_pressure",
            FIELD_PRESSURE,
            FitContributor.DATA_TYPE_FLOAT,
            { :mesgType => FitContributor.MESG_TYPE_RECORD, :units => "Pa" }
        );
        Logger.info("SessionManager.startSession: before createField(accelG)");
        _accelGField = session.createField(
            "accel_g",
            FIELD_ACCEL_G,
            FitContributor.DATA_TYPE_FLOAT,
            { :mesgType => FitContributor.MESG_TYPE_RECORD, :units => "G" }
        );
        if (_pressureField == null || _accelGField == null) {
            Logger.warn("session: record telemetry fields unavailable");
        }
        Logger.info("SessionManager.startSession: after createField (all)");
        if (hField == null || lField == null || aField == null) {
            Logger.error("session: createField returned null for one or more lap fields");
            session.discard();
            _state = STATE_IDLE;
            return false;
        }

        Logger.info("SessionManager.startSession: before session.start()");
        var started = session.start();
        Logger.info("SessionManager.startSession: after session.start() -> " + started);
        if (!started) {
            Logger.error("session: start() failed");
            session.discard();
            _state = STATE_IDLE;
            return false;
        }

        _session      = session;
        _heightField  = hField;
        _lengthField  = lField;
        _airtimeField = aField;
        _jumpCount    = 0;
        _state        = STATE_RECORDING;

        Logger.info("session: STARTING -> RECORDING (sport=" + sport + ")");
        return true;
    }

    // ------------------------------------------------------------------
    // stopSession
    //
    // Stops and saves the active session, then nulls the session and
    // field references per SDK memory guidance. Safe to call only
    // from STATE_RECORDING.
    // ------------------------------------------------------------------

    function stopSession() as Boolean {
        Logger.info("SessionManager.stopSession: entered (state=" + getStateName() + ")");
        if (_state != STATE_RECORDING || _session == null) {
            Logger.warn("stopSession: rejected, current state=" + getStateName());
            return false;
        }

        Logger.info("session: RECORDING -> STOPPING (jumps=" + _jumpCount + ")");
        _state = STATE_STOPPING;

        var session = _session;
        // The trailing lap Garmin auto-closes at stop() inherits the last
        // setData values, which duplicated the final jump in the FIT.
        // Zero them so the trailing lap reads as "no jump".
        try {
            if (_heightField != null) { _heightField.setData(0.0); }
            if (_lengthField != null) { _lengthField.setData(0.0); }
            if (_airtimeField != null) { _airtimeField.setData(0.0); }
        } catch (eZero) {
            Logger.warn("stopSession: zeroing lap fields failed e=" + eZero);
        }
        Logger.info("SessionManager.stopSession: before session.stop()");
        var stopped = session.stop();
        Logger.info("SessionManager.stopSession: after session.stop() -> " + stopped);
        Logger.info("SessionManager.stopSession: before session.save()");
        var saved   = session.save();
        Logger.info("SessionManager.stopSession: after session.save() -> " + saved);

        // Free references per SDK guidance.
        _session      = null;
        _heightField  = null;
        _lengthField  = null;
        _airtimeField = null;
        _pressureField = null;
        _accelGField  = null;

        if (!stopped || !saved) {
            _state = STATE_IDLE;
            Logger.error("session: stop()/save() failed (stopped=" + stopped + " saved=" + saved + ") -> IDLE");
            return false;
        }

        _state = STATE_SAVED;
        Logger.info("session: STOPPING -> SAVED (jumps=" + _jumpCount + ")");
        return true;
    }

    // ------------------------------------------------------------------
    // addJumpLap
    //
    // Records a single jump as a FIT lap. setData() MUST be called for
    // all three custom fields BEFORE addLap() so the values are
    // captured with the lap boundary. Returns the result of addLap().
    // ------------------------------------------------------------------

    // Record-level telemetry. Called from the sensor callbacks at their
    // own cadence; the session snapshots the pending values into each
    // record it writes. Cheap no-ops when the fields are unavailable.

    function setRecordPressure(pa as Number) as Void {
        var f = _pressureField;
        if (f != null) {
            try { f.setData(pa); } catch (e) { _pressureField = null; }
        }
    }

    function setRecordAccelG(g as Float) as Void {
        var f = _accelGField;
        if (f != null) {
            try { f.setData(g); } catch (e) { _accelGField = null; }
        }
    }

    function addJumpLap(jump as Dictionary) as Boolean {
        Logger.info("SessionManager.addJumpLap: entered (state=" + getStateName() + ")");
        if (_state != STATE_RECORDING || _session == null) {
            Logger.warn("addJumpLap: rejected, current state=" + getStateName());
            return false;
        }
        if (_heightField == null || _lengthField == null || _airtimeField == null) {
            Logger.error("addJumpLap: one or more lap fields are null");
            return false;
        }

        var heightM    = jump.get(:heightM);
        var lengthM    = jump.get(:lengthM);
        var duration   = jump.get(:durationMs);
        if (heightM    == null) { heightM    = 0; }
        if (lengthM    == null) { lengthM    = 0; }
        if (duration   == null) { duration   = 0; }

        var baroH  = heightM.toFloat();

        // Height sanity. Above 20 m is not a kiteboarding jump on a
        // wrist sensor; it means the pressure series was corrupt. Drop
        // the row rather than pollute the FIT file.
        if (baroH > 20.0) {
            _skippedSanity++;
            Logger.info("session: jump skipped sanity (baro=" + baroH.format("%.1f") + "m)");
            return false;
        }

        // Length sanity. An implausible length means GPS anchoring
        // failed, not that the jump was fake - the height and airtime
        // are still good - so clamp the field instead of dropping the
        // whole lap. Discarding here used to be invisible: the jump
        // stayed in the session list with :recorded = false and simply
        // vanished from the review screen.
        var lengthOut = lengthM.toFloat();
        if (lengthOut > 100.0) {
            Logger.info("session: length clamped (" + lengthOut.format("%.1f") + "m)");
            lengthOut = 0.0;
        }

        // Lower gates live in JumpDetector (BARO_DIP_PA, MIN_FLIGHT_MS).
        // Duplicating them here let the two drift apart, so only the
        // sanity caps above remain.
        var airtimeS = duration.toFloat() / 1000.0;
        Logger.info(
            "SessionManager.addJumpLap: values"
            + " heightM=" + baroH.format("%.1f")
            + " lengthM=" + lengthOut.format("%.1f")
            + " airtimeS=" + airtimeS.format("%.2f")
        );

        Logger.info("SessionManager.addJumpLap: before setData (all fields)");
        _heightField.setData(baroH);
        _lengthField.setData(lengthOut);
        _airtimeField.setData(airtimeS);
        Logger.info("SessionManager.addJumpLap: after setData");

        Logger.info("SessionManager.addJumpLap: before addLap()");
        var ok = _session.addLap();
        Logger.info("SessionManager.addJumpLap: after addLap() -> " + ok);
        if (ok) {
            _jumpCount++;
            Logger.info(
                "session: lap added (count=" + _jumpCount
                + " heightM=" + baroH.format("%.1f")
                + " lengthM=" + lengthOut.format("%.1f")
                + " airtimeS=" + airtimeS.format("%.2f") + ")"
            );
        } else {
            Logger.error("session: addLap() returned false");
        }
        return ok;
    }
}
