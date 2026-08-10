// StartView
//
// Phase 3 chunk 2. The first view the user sees when launching
// Kite Tracker. It is a static, non-interactive screen with a title
// and a hint to press START. Pressing START is handled by the
// AppInputDelegate attached by App.getInitialView().

import Toybox.Graphics;
import Toybox.Lang;
import Toybox.WatchUi;

class StartView extends WatchUi.View {

    function initialize() {
        Logger.info("StartView.initialize: entered");
        View.initialize();
        Logger.info("StartView.initialize: done");
    }

    function onUpdate(dc as Graphics.Dc) as Void {
        Logger.info("StartView.onUpdate: entered");
        dc.setColor(Graphics.COLOR_BLACK, Graphics.COLOR_BLACK);
        dc.clear();

        var cx = dc.getWidth() / 2;
        var lineH = dc.getFontHeight(Graphics.FONT_MEDIUM);

        dc.setColor(Graphics.COLOR_WHITE, Graphics.COLOR_TRANSPARENT);

        // Title in medium font, vertically centred above the hint lines.
        var y = (dc.getHeight() - lineH * 3) / 2;
        dc.drawText(cx, y, Graphics.FONT_MEDIUM, "Kite Tracker", Graphics.TEXT_JUSTIFY_CENTER);

        // Two-line hint in small font below the title.
        y += lineH * 2;
        dc.drawText(cx, y, Graphics.FONT_SMALL, "Press START", Graphics.TEXT_JUSTIFY_CENTER);

        y += lineH;
        dc.drawText(cx, y, Graphics.FONT_SMALL, "to begin session", Graphics.TEXT_JUSTIFY_CENTER);
    }
}
