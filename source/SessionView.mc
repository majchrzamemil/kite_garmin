// SessionView
//
// Phase 3 chunk 2. Live screen shown while a FIT recording session is
// active. Displays the current jump count and a hint to press START
// to stop. The view caches a local copy of the jump count so App can
// call setJumpCount() + requestUpdate() from the sensor callback
// without forcing an immediate redraw from inside the callback.

import Toybox.Graphics;
import Toybox.Lang;
import Toybox.WatchUi;

class SessionView extends WatchUi.View {

    var _sessionManager as SessionManager;
    var _jumpCount as Number;
    var _app as App;

    function initialize(sessionManager as SessionManager, app as App) {
        Logger.info("SessionView.initialize: entered (initial jumps=" + sessionManager.getJumpCount() + ")");
        View.initialize();
        _sessionManager = sessionManager;
        _app = app;
        _jumpCount = sessionManager.getJumpCount();
        Logger.info("SessionView.initialize: done");
    }

    // Called by App._checkForLandedJump() after a new lap is recorded.
    // We just cache the new value; the actual redraw is scheduled via
    // requestUpdate() which the caller invokes immediately after.

    function setJumpCount(count as Number) as Void {
        Logger.info("SessionView.setJumpCount: " + _jumpCount + " -> " + count);
        _jumpCount = count;
    }

    function requestUpdate() as Void {
        Logger.info("SessionView.requestUpdate: scheduling UI redraw");
        WatchUi.requestUpdate();
    }

    function onUpdate(dc as Graphics.Dc) as Void {
        Logger.info("SessionView.onUpdate: entered");
        // If the sensor callback flagged a pending jump, push the
        // SummaryView on the UI thread (where onUpdate runs) instead
        // of from inside the sensor callback. This avoids the "IQ!"
        // crash caused by calling WatchUi.pushView from a non-UI thread.
        if (_app != null) {
            _app.pushPendingSummaryView();
        }

        dc.setColor(Graphics.COLOR_BLACK, Graphics.COLOR_BLACK);
        dc.clear();

        var cx = dc.getWidth() / 2;
        var lineH = dc.getFontHeight(Graphics.FONT_MEDIUM);

        dc.setColor(Graphics.COLOR_WHITE, Graphics.COLOR_TRANSPARENT);

        // Status line at the top.
        var y = lineH;
        dc.drawText(cx, y, Graphics.FONT_MEDIUM, "Recording...", Graphics.TEXT_JUSTIFY_CENTER);

        // Jump count in the middle of the screen.
        y = (dc.getHeight() - lineH) / 2;
        dc.drawText(cx, y, Graphics.FONT_MEDIUM, "Jumps: " + _jumpCount, Graphics.TEXT_JUSTIFY_CENTER);

        // Stop hint near the bottom.
        y = dc.getHeight() - lineH * 2;
        dc.drawText(cx, y, Graphics.FONT_SMALL, "Press START to stop", Graphics.TEXT_JUSTIFY_CENTER);
    }
}
