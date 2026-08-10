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
        var heightAccelM = jump.get(:heightAccelM);
        var duration = jump.get(:durationMs);
        if (heightM      == null) { heightM      = 0; }
        if (heightAccelM == null) { heightAccelM = 0; }
        if (duration     == null) { duration     = 0; }
        Logger.info(
            "SummaryView.initialize: entered"
            + " endTs=" + endTs
            + " heightM=" + heightM.toFloat().format("%.1f")
            + " heightAccelM=" + heightAccelM.toFloat().format("%.1f")
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

        var ah = _jump.get(:heightAccelM);
        var bh = _jump.get(:heightM);
        var t  = _jump.get(:durationMs);
        var l  = _jump.get(:lengthM);
        if (ah == null) { ah = 0; }
        if (bh == null) { bh = 0; }
        if (t  == null) { t  = 0; }
        if (l  == null) { l  = 0; }

        var durationS = t.toFloat() / 1000.0;

        // Layout: single horizontal line of all four metrics, well clear
        // of the Instinct Solar 2 bezel cutout.
        var w = dc.getWidth();
        var h = dc.getHeight();
        var cx = w / 2;
        var cy = h / 2;

        var txt = "AH " + ah.toFloat().format("%.1f")
            + " BH " + bh.toFloat().format("%.1f")
            + " T " + durationS.format("%.1f") + "s"
            + " L " + l.toFloat().format("%.1f") + "m";

        dc.setColor(Graphics.COLOR_WHITE, Graphics.COLOR_TRANSPARENT);
        dc.drawText(cx, cy, Graphics.FONT_TINY, txt, Graphics.TEXT_JUSTIFY_CENTER);
    }
}
