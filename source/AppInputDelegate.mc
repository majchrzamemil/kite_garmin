// AppInputDelegate
//
// Phase 3 chunk 2. Single input delegate shared by every session
// view. Listens for START/ENTER presses and toggles the recording
// session via App.beginSession() / App.endSession(). All other keys
// (BACK, MENU, LAP, etc.) are returned unhandled so the Connect IQ
// framework can apply its default behaviour (pop the view stack or
// quit the app).

import Toybox.Lang;
import Toybox.WatchUi;

class AppInputDelegate extends WatchUi.InputDelegate {

    var _app as App;

    function initialize(app as App) {
        InputDelegate.initialize();
        _app = app;
    }

    function onKey(evt as WatchUi.KeyEvent) as Boolean {
        var key = evt.getKey();
        if (evt.getType() != WatchUi.PRESS_TYPE_ACTION) {
            return false;
        }
        if (key == WatchUi.KEY_START || key == WatchUi.KEY_ENTER) {
            if (_app.isRecording()) {
                _app.endSession();
            } else {
                _app.beginSession();
            }
            return true;
        }
        // Review the last session from the start screen. BACK-exits
        // cannot show the review at stop time, so it waits here.
        if ((key == WatchUi.KEY_UP || key == WatchUi.KEY_DOWN)
                && !_app.isRecording() && _app.hasLastSession()) {
            _app.showLastSessionReview();
            return true;
        }
        return false;
    }
}
