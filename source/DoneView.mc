// DoneView
//
// Phase 3 chunk 2. End-of-session summary shown after the user stops
// recording. Displays jump count, total airtime, and a reminder that
// the activity will sync to Garmin Connect. Pressing BACK is left to
// the system so the app exits naturally when the user is done.

import Toybox.Graphics;
import Toybox.Lang;
import Toybox.WatchUi;

class DoneView extends WatchUi.View {

    var _jumpCount as Number;
    var _totalAirtimeS as Float;

    function initialize(jumpCount as Number, totalAirtimeS as Float) {
        Logger.info("DoneView.initialize: entered (jumps=" + jumpCount + " airtimeS=" + totalAirtimeS.format("%.2f") + ")");
        View.initialize();
        _jumpCount = jumpCount;
        _totalAirtimeS = totalAirtimeS;
        Logger.info("DoneView.initialize: done");
    }

    function onUpdate(dc as Graphics.Dc) as Void {
        Logger.info("DoneView.onUpdate: entered");
        dc.setColor(Graphics.COLOR_BLACK, Graphics.COLOR_BLACK);
        dc.clear();

        var cx = dc.getWidth() / 2;
        var smallH = dc.getFontHeight(Graphics.FONT_SMALL);
        var mediumH = dc.getFontHeight(Graphics.FONT_MEDIUM);

        dc.setColor(Graphics.COLOR_WHITE, Graphics.COLOR_TRANSPARENT);

        // Headline.
        var y = mediumH;
        dc.drawText(cx, y, Graphics.FONT_MEDIUM, "Session saved", Graphics.TEXT_JUSTIFY_CENTER);

        // Stats block.
        y = mediumH * 3;
        dc.drawText(cx, y, Graphics.FONT_SMALL, "Jumps: " + _jumpCount, Graphics.TEXT_JUSTIFY_CENTER);

        y += smallH;
        dc.drawText(cx, y, Graphics.FONT_SMALL, "Airtime: " + _totalAirtimeS.format("%.1f") + " s", Graphics.TEXT_JUSTIFY_CENTER);

        // Sync reminder.
        y += smallH * 2;
        dc.drawText(cx, y, Graphics.FONT_SMALL, "Sync to Connect", Graphics.TEXT_JUSTIFY_CENTER);

        // Exit hint near the bottom.
        y = dc.getHeight() - smallH * 2;
        dc.drawText(cx, y, Graphics.FONT_SMALL, "Press BACK", Graphics.TEXT_JUSTIFY_CENTER);
    }
}
