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

    var _state        as Number;
    var _session      as ActivityRecording.Session?;
    var _heightField  as FitContributor.Field?;
    var _lengthField  as FitContributor.Field?;
    var _airtimeField as FitContributor.Field?;
    var _jumpCount    as Number;

    function initialize() {
        _state        = STATE_IDLE;
        _session      = null;
        _heightField  = null;
        _lengthField  = null;
        _airtimeField = null;
        _jumpCount    = 0;
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
        Logger.info("SessionManager.startSession: after createField (all three)");
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

        // Upper-bound sanity discard. A barometric height above 20 m
        // or a takeoff-to-landing distance above 100 m cannot be a
        // realistic kiteboarding jump on the wrist-mounted sensor.
        // Such values usually mean the median-filtered _minPressure
        // path (or a future path) produced a corrupt altitude, or the
        // rider covered a long stretch of water without an actual
        // jump. Drop the row instead of polluting the FIT file.
        if (baroH > 20.0 || lengthM.toFloat() > 100.0) {
            Logger.info("session: jump skipped sanity (baro=" + baroH.format("%.1f")
                + "m length=" + lengthM.toFloat().format("%.1f") + "m)");
            return false;
        }

        // Two-part filter. The barometric check rejects jumps whose
        // peak altitude never reaches 1.5 m above the takeoff baseline.
        // The airtime check is a backup for the detector's
        // MIN_FLIGHT_MS gate: if for any reason a sub-1-second jump
        // reaches addJumpLap (e.g. a future code path bypasses the
        // detector's _maybeLand guard) we still refuse to record it as
        // a FIT lap. The matching detector-side check is the
        // MIN_FLIGHT_MS early return in JumpDetector._maybeLand().
        var airtimeS = duration.toFloat() / 1000.0;
        if (baroH <= 1.5 || airtimeS <= 1.0) {
            Logger.info("session: jump skipped (baro=" + baroH.format("%.1f") + "m airtime=" + airtimeS.format("%.2f") + "s)");
            return false;
        }
        Logger.info(
            "SessionManager.addJumpLap: values"
            + " heightM=" + baroH.format("%.1f")
            + " lengthM=" + lengthM.toFloat().format("%.1f")
            + " airtimeS=" + airtimeS.format("%.2f")
        );

        Logger.info("SessionManager.addJumpLap: before setData (all fields)");
        _heightField.setData(baroH);
        _lengthField.setData(lengthM.toFloat());
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
                + " lengthM=" + lengthM.toFloat().format("%.1f")
                + " airtimeS=" + airtimeS.format("%.2f") + ")"
            );
        } else {
            Logger.error("session: addLap() returned false");
        }
        return ok;
    }
}
