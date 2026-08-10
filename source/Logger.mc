// Logger
//
// Thin wrapper around System.println that prefixes every line with
// [KITE] so simulator log scraping (and the verification harness) can
// isolate this app's output from the device noise.

import Toybox.System;

class Logger {

    static const TAG = "[KITE]";

    static function info(msg) as Void {
        System.println(TAG + " " + msg);
    }

    static function warn(msg) as Void {
        System.println(TAG + " WARN " + msg);
    }

    static function error(msg) as Void {
        System.println(TAG + " ERROR " + msg);
    }
}
