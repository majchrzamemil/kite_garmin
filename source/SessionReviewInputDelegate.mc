// SessionReviewInputDelegate
//
// Phase 4 chunk 2. Input delegate for SessionReviewView. Maps the
// watch's UP/DOWN physical buttons to prev/next jump navigation.
// START, ENTER, BACK and any other key fall through to the framework
// (return false) so BACK can exit the view normally.

import Toybox.Lang;
import Toybox.WatchUi;

class SessionReviewInputDelegate extends WatchUi.InputDelegate {

    var _view as SessionReviewView;

    function initialize(view as SessionReviewView) {
        InputDelegate.initialize();
        _view = view;
        Logger.info("SessionReviewInputDelegate.initialize: attached");
    }

    function onKey(evt as WatchUi.KeyEvent) as Boolean {
        // Only react on key release (ACTION). Swallow release/key-held
        // events so a single press does not advance two jumps.
        if (evt.getType() != WatchUi.PRESS_TYPE_ACTION) {
            return false;
        }
        var key = evt.getKey();
        if (key == WatchUi.KEY_UP) {
            _view.prevJump();
            return true;
        }
        if (key == WatchUi.KEY_DOWN) {
            _view.nextJump();
            return true;
        }
        // KEY_START, KEY_ENTER, KEY_BACK and any other key fall through
        // to the framework so BACK exits the view stack normally and
        // START/ENTER behave like in other views (no-op here, handled
        // by the system).
        return false;
    }
}
