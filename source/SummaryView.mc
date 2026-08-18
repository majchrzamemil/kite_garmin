// SummaryView
//
// Phase 2 step 3. A short-lived view that pops up after a jump lands
// and shows the rider the height, length, and airtime for a few
// seconds before returning to the session view.

import Toybox.Graphics;
import Toybox.Lang;
import Toybox.System;
import Toybox.Timer;
import Toybox.WatchUi;

class SummaryView extends WatchUi.View {

    var _jump as Dictionary;
    var _closeTimer as Timer.Timer?;

    function initialize(jump as Dictionary) {
        var endTs = jump[:endTs];
        var heightM = jump.get(:heightM);
        var duration = jump.get(:durationMs);
        if (heightM  == null) { heightM  = 0; }
        if (duration == null) { duration = 0; }
        Logger.info(
            "SummaryView.initialize: entered"
            + " endTs=" + endTs
            + " heightM=" + heightM.toFloat().format("%.1f")
            + " durationMs=" + duration
        );
        View.initialize();
        _jump = jump;
        _closeTimer = null;
        Logger.info("SummaryView.initialize: done");
    }

    function onShow() {
        View.onShow();
        _closeTimer = new Timer.Timer();
        _closeTimer.start(method(:onTimeout), 5000, false);
    }

    function onHide() {
        View.onHide();
        if (_closeTimer != null) {
            _closeTimer.stop();
            _closeTimer = null;
        }
    }

    function onTimeout() as Void {
        _closeTimer = null;
        WatchUi.popView(WatchUi.SLIDE_IMMEDIATE);
    }

    function onUpdate(dc as Graphics.Dc) as Void {
        Logger.info("SummaryView.onUpdate: entered");
        dc.setColor(Graphics.COLOR_BLACK, Graphics.COLOR_BLACK);
        dc.clear();

        var bh = _jump.get(:heightM);
        var t  = _jump.get(:durationMs);
        var l  = _jump.get(:lengthM);
        if (bh == null) { bh = 0; }
        if (t  == null) { t  = 0; }
        if (l  == null) { l  = 0; }

        var durationS = t.toFloat() / 1000.0;

        var w = dc.getWidth();
        var h = dc.getHeight();
        var cx = w / 2;

        // Instinct Solar 2 safe area: avoid the top-right circular
        // bezel/button cutout. Keep everything centered in the middle
        // of the screen.
        var margin = 18;
        var safeBottom = h - margin;

        dc.setColor(Graphics.COLOR_WHITE, Graphics.COLOR_TRANSPARENT);

        // Big centered height: e.g. "4.2m". FONT_NUMBER_MEDIUM only
        // contains glyphs for digits, so the "m" renders as a box/X.
        // Use FONT_LARGE instead — it supports letters and is still
        // large enough to read at a glance.
        var bigH = dc.getFontHeight(Graphics.FONT_LARGE);
        var heightY = (h - bigH) / 2 - 6;
        dc.drawText(cx, heightY, Graphics.FONT_LARGE,
            bh.toFloat().format("%.1f") + "m",
            Graphics.TEXT_JUSTIFY_CENTER);

        // Time + travel below the height, small and unlabeled.
        var smallH = dc.getFontHeight(Graphics.FONT_SMALL);
        var detailY = heightY + bigH + 4;
        var detail = durationS.format("%.1f") + "s  " + l.toFloat().format("%.1f") + "m";
        dc.drawText(cx, detailY, Graphics.FONT_SMALL,
            detail,
            Graphics.TEXT_JUSTIFY_CENTER);

        // Keep drawing inside safe vertical bounds; if the detail
        // would clip, nudge it upward slightly.
        if (detailY + smallH > safeBottom) {
            detailY = safeBottom - smallH;
            dc.setColor(Graphics.COLOR_BLACK, Graphics.COLOR_BLACK);
            dc.clear();
            dc.setColor(Graphics.COLOR_WHITE, Graphics.COLOR_TRANSPARENT);
            dc.drawText(cx, heightY, Graphics.FONT_LARGE,
                bh.toFloat().format("%.1f") + "m",
                Graphics.TEXT_JUSTIFY_CENTER);
            dc.drawText(cx, detailY, Graphics.FONT_SMALL,
                detail,
                Graphics.TEXT_JUSTIFY_CENTER);
        }
    }
}
