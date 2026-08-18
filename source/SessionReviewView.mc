// SessionReviewView
//
// Phase 4 chunk 1. Scrollable end-of-session review. After the user
// stops a session, this view shows every detected jump (recorded and
// filtered) one per screen. The user navigates with the watch
// UP/DOWN keys; BACK exits via the framework. Designed for the
// Instinct Solar 2 (176x176 px semi-octagon display) — safe area is
// roughly a 140 px diameter circle in the middle of the screen.

import Toybox.Graphics;
import Toybox.Lang;
import Toybox.WatchUi;

class SessionReviewView extends WatchUi.View {

    var _jumps as Array<Dictionary>;
    var _index as Number;
    var _totalAirtimeS as Float;
    var _recordedCount as Number;

    function initialize(jumps as Array<Dictionary>, totalAirtimeS as Float, recordedCount as Number) {
        View.initialize();
        _jumps = _filterRecorded(jumps);
        _index = 0;
        _totalAirtimeS = totalAirtimeS == null ? 0.0f : totalAirtimeS;
        _recordedCount = recordedCount == null ? 0 : recordedCount;
        Logger.info(
            "SessionReviewView.initialize: entered"
            + " detected=" + (jumps == null ? 0 : jumps.size())
            + " recorded=" + _jumps.size()
            + " airtimeS=" + _totalAirtimeS.format("%.2f")
        );
    }

    // The review view is for jumps that actually got written to the
    // FIT file. Filter out anything SessionManager discarded.
    function _filterRecorded(jumps as Array<Dictionary>?) as Array<Dictionary> {
        var out = [] as Array<Dictionary>;
        if (jumps == null) {
            return out;
        }
        var i = 0;
        while (i < jumps.size()) {
            var j = jumps[i];
            var rec = j.get(:recorded);
            if (rec != null && (rec as Boolean)) {
                out.add(j);
            }
            i++;
        }
        return out;
    }

    // Advance to the next jump, wrapping from the last entry back to
    // the first so a rider never gets stuck at the bottom of the list.
    function nextJump() as Void {
        if (_jumps.size() == 0) {
            return;
        }
        _index = (_index + 1) % _jumps.size();
        WatchUi.requestUpdate();
    }

    // Step backwards to the previous jump, wrapping from the first
    // entry back to the last.
    function prevJump() as Void {
        if (_jumps.size() == 0) {
            return;
        }
        _index = _index - 1;
        if (_index < 0) {
            _index = _jumps.size() - 1;
        }
        WatchUi.requestUpdate();
    }

    // Translate a JumpDetector landing-path code back to a
    // human-readable string for on-screen display. Must stay in
    // lock-step with JumpDetector._landingPathToCode():
    // 0="pressure", 1="gps", 2="lowG", 3="timeout", -1 (and anything
    // else)="unknown".
    function _codeToLandingPath(code as Number) as String {
        if (code == 0) { return "pressure"; }
        if (code == 1) { return "gps"; }
        if (code == 2) { return "lowG"; }
        if (code == 3) { return "timeout"; }
        return "unknown";
    }

    function onUpdate(dc as Graphics.Dc) as Void {
        dc.setColor(Graphics.COLOR_BLACK, Graphics.COLOR_BLACK);
        dc.clear();
        dc.setColor(Graphics.COLOR_WHITE, Graphics.COLOR_TRANSPARENT);

        var w = dc.getWidth();
        var h = dc.getHeight();

        // Empty-session placeholder. No jumps were recorded (or every
        // jump was filtered out by SessionManager), so there is nothing
        // to scroll through — just a hint to exit.
        if (_jumps.size() == 0) {
            var cx = w / 2;
            var cy = h / 2;
            var smallH = dc.getFontHeight(Graphics.FONT_SMALL);
            dc.drawText(cx, cy - smallH,
                Graphics.FONT_SMALL, "No jumps",
                Graphics.TEXT_JUSTIFY_CENTER);
            dc.drawText(cx, cy + 2,
                Graphics.FONT_TINY, "BACK to exit",
                Graphics.TEXT_JUSTIFY_CENTER);
            return;
        }

        // Defensive clamp so an out-of-range _index (e.g. after the
        // backing list was mutated externally) cannot crash onUpdate.
        if (_index < 0) { _index = 0; }
        if (_index >= _jumps.size()) { _index = _jumps.size() - 1; }

        var jump = _jumps[_index];

        // Defensive field reads — a half-populated jump (e.g. GPS never
        // fixed so lengthM is 0) must still render a sensible row.
        var hM  = jump.get(:heightM);
        var l   = jump.get(:lengthM);
        var t   = jump.get(:durationMs);
        if (hM == null) { hM = 0; }
        if (l  == null) { l  = 0; }
        if (t  == null) { t  = 0; }

        var airtimeS = t.toFloat() / 1000.0;

        // ----------------------------------------------------------------
        // Layout
        //
        // The Instinct Solar 2 has a 176x176 px display with a
        // semi-octagon bezel that crops the corners. Keep everything
        // centered in the safe middle area; avoid the top-right
        // circular cutout entirely.
        // ----------------------------------------------------------------

        var margin = 16;
        var smallH = dc.getFontHeight(Graphics.FONT_SMALL);
        var largeH = dc.getFontHeight(Graphics.FONT_LARGE);

        // ----- Header row: jump index on the left, total airtime on the right.
        var header = "Jump " + (_index + 1) + "/" + _jumps.size();
        var totalStr = "T " + _totalAirtimeS.format("%.1f") + "s";
        dc.drawText(margin, margin,
            Graphics.FONT_SMALL, header,
            Graphics.TEXT_JUSTIFY_LEFT);
        dc.drawText(w - margin, margin,
            Graphics.FONT_SMALL, totalStr,
            Graphics.TEXT_JUSTIFY_RIGHT);

        // ----- Big centered height (e.g. "4.2m").
        var heightStr = hM.toFloat().format("%.1f") + "m";
        var heightY = (h - largeH) / 2 - 4;
        dc.drawText(w / 2, heightY, Graphics.FONT_LARGE,
            heightStr,
            Graphics.TEXT_JUSTIFY_CENTER);

        // ----- Length and airtime below, unlabeled.
        var detailY = heightY + largeH + 8;
        var detail = l.toFloat().format("%.1f") + "m  " + airtimeS.format("%.1f") + "s";
        dc.drawText(w / 2, detailY, Graphics.FONT_SMALL,
            detail,
            Graphics.TEXT_JUSTIFY_CENTER);

        // ----- Footer hint: UP/DOWN to scroll, BACK to exit.
        var hintY = h - margin - smallH;
        dc.drawText(w / 2, hintY, Graphics.FONT_SMALL,
            "UP/DOWN · BACK",
            Graphics.TEXT_JUSTIFY_CENTER);
    }
}
