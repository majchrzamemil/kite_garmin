# Side-load kite_garmin to a Garmin Instinct Solar 2

This guide explains how to install the app on a physical watch for real-world testing. The simulator is fine for early development, but sensors behave differently on the actual device, so at some point you will want to run the `.prg` on the watch itself.

> Target device: **Garmin Instinct Solar 2** (`instinct2` product id in the SDK).  
> Host: **macOS** with the Connect IQ SDK already installed (see `docs/ENVIRONMENT.md`).

---

## 1. Build a device `.prg`

A simulator build and a device build are the same command for our project because the manifest lists only `instinct2`:

```bash
cd /Users/em/Documents/repos/kite_garmin
rm -rf build
monkeyc -o build/app.prg -d instinct2 -f monkey.jungle
```

Expected output:

```
BUILD SUCCESSFUL
```

Example from the current SDK:

```
$ monkeyc -o build/app.prg -d instinct2 -f monkey.jungle
BUILD SUCCESSFUL
$ ls -la build/app.prg
-rw-r--r--  1 em  staff  113900 Aug  9 19:01 build/app.prg
```

and a file at:

```
build/app.prg
```

If you see `Use command line option: -y`, make sure the `/opt/homebrew/bin/monkeyc` wrapper is in place (see `docs/ENVIRONMENT.md` §5) and that `~/.Garmin/connect_iq_dev_key.der` exists.

---

## 2. Connect the watch to your Mac

1. Plug the watch into the Mac with Garmin's USB cable.
2. On the watch you may see a prompt like "USB Charging Only" or "File Transfer"; choose **File Transfer / MTP** if it asks.
3. On macOS the Instinct Solar 2 mounts as a normal FAT drive at `/Volumes/GARMIN`. The real Garmin file system is nested one level deeper at `/Volumes/GARMIN/GARMIN/`.

### macOS MTP client: OpenMTP (optional)

If the watch does not mount as a drive on your Mac, use [OpenMTP](https://openmtp.ganeshrvel.com/):

1. Download and install OpenMTP.
2. Launch OpenMTP.
3. Make sure **Garmin Express is completely quit** (also the menu-bar icon).
4. Select the watch in OpenMTP; you should see the `GARMIN` folder and then the inner `GARMIN/Apps/` folder.

---

## 3. Copy the `.prg` to the correct `GARMIN/Apps/` folder

> **Important:** On the Instinct Solar 2 the correct path is `/Volumes/GARMIN/GARMIN/Apps/`, not `/Volumes/GARMIN/Apps/`. The top-level `/Volumes/GARMIN/Apps/` folder is ignored by the watch.

Using the direct mount:

```bash
APPS_DIR="/Volumes/GARMIN/GARMIN/Apps"
mkdir -p "$APPS_DIR"
mkdir -p "$APPS_DIR/LOGS"
cp build/app.prg "$APPS_DIR/app.prg"
# On Instinct Solar 2, the system logger writes to UPPERCASE "APP.TXT"
# (case-sensitive FAT). Create that ourselves AND let the watch create
# its own on first crash by also leaving a lowercase file.
touch "$APPS_DIR/LOGS/APP.TXT"
touch "$APPS_DIR/LOGS/app.TXT"
```

Or in OpenMTP:

1. Open the outer `GARMIN` drive.
2. Open the inner `GARMIN` folder, then `Apps`.
3. Copy `build/app.prg` into `GARMIN/Apps/`.
4. Create the `LOGS` folder inside `GARMIN/Apps/` if it does not exist.
5. Create an empty file named **`APP.TXT`** (uppercase) in `GARMIN/Apps/LOGS/`. Optionally also create `app.TXT` as a fallback.
6. Eject the watch safely.

The app now lives on the watch as `/GARMIN/GARMIN/Apps/app.prg`.

---

## 4. Launch the app on the watch

1. From the watchface, press **START** (top-right button) to open the activities/apps list.
2. Scroll through the list and look for **Kite Tracker** (the name set in `resources/strings/strings.xml`).
3. Select it to launch.

If the app does not appear, power cycle the watch:

- Hold **LIGHT/MENU** (top-left) until the power menu appears.
- Select **Power Off**.
- Press **LIGHT/MENU** again to turn it back on.
- Press **START** and check again.

---

## 5. Capture real-watch logs

`System.println` lines from a side-loaded app do not appear in the simulator log. They are written to a text file in the `GARMIN/Apps/LOGS/` folder with the **same base name as the `.prg`**, and the Instinct Solar 2's FAT filesystem is **case-sensitive**, so the file must be named `APP.TXT` (uppercase) to match `app.prg`.

1. Create the folder `/Volumes/GARMIN/GARMIN/Apps/LOGS/` if it does not exist.
2. Create an empty file named **`APP.TXT`** (uppercase) on your Mac and copy it into `GARMIN/Apps/LOGS/`.
3. (Optional) Also create a lowercase `app.TXT` in the same folder as a fallback for older firmware.
4. Run the app on the watch.
5. If the app crashes, the watch may also create its own `APP.TXT` on first crash even if you did not pre-create one.
6. Reconnect the watch and download `GARMIN/Apps/LOGS/APP.TXT`.
7. Open it in a text editor. Lines prefixed with `[KITE]` come from our `Logger.mc`.

If neither `APP.TXT` nor `app.TXT` exists, `System.println` output is silently discarded.

> **Tip:** if you only see `app.TXT` being created/updated by the watch (and not `APP.TXT`), your `System.println` output is going to a file the SDK is creating with a lowercase name. Rename your pre-created file to match what the watch uses; on Instinct Solar 2 this is uppercase.

---

## 6. Update the app after changes

Build the `.prg` again and overwrite `GARMIN/Apps/app.prg` with the new file. The app id in `manifest.xml` must stay the same for the watch to treat it as the same app; otherwise the old copy may remain and you will see two entries.

---

## 7. Remove the app from the watch

1. Connect the watch via USB or OpenMTP.
2. Delete `GARMIN/Apps/app.prg` and `GARMIN/Apps/LOGS/APP.TXT` (and `app.TXT` if you also created one).
3. Eject and power cycle the watch.

On some newer watches the file system is hidden; if you cannot see the `.prg`, delete it from the watch instead:

- Menu → Settings → Apps → Kite Tracker → Delete.

---

## 8. Alternative: install via Connect IQ Store (beta)

If USB file transfer is unreliable, publish the app as a **private beta**:

1. In VS Code, run **Monkey C: Export Project**. This produces an `.iq` file.
2. Log in to the [Garmin Developer Portal](https://developer.garmin.com/).
3. Create a new app entry, upload the `.iq`, and set it to **Beta**.
4. On your phone, open the Garmin Connect / Connect IQ app while signed in to the same Garmin account.
5. Find the beta listing and install it directly from the store.

Beta apps are visible only to your account and do not go through public review. This is the easiest way to test app settings on a real device, because side-loaded `.prg` files cannot create the `.SET` settings file automatically.

---

## 9. Displaying custom FIT fields in Garmin Connect

Side-loaded apps save custom FitContributor data correctly in the FIT file, but Garmin Connect will not display those columns because that rendering metadata comes from the app-store JSON, not from your code. To make the custom lap fields visible in Garmin Connect (height, length, airtime, accel height), publish the app as a private beta:

1. In VS Code, run **Monkey C: Export Project** to produce a `.iq` file.
2. Log in to the [Garmin Developer Portal](https://developer.garmin.com/).
3. Create a new app entry, upload the `.iq`, and set it to **Beta** (private).
4. On your phone, open the Garmin Connect / Connect IQ app while signed in to the same Garmin account.
5. Find the beta listing and install it directly from the store.
6. After recording a session and syncing, the custom lap fields will appear in the activity's lap view.

Note: this also avoids the spurious "Sync Failed" message on some Instinct firmware versions.

## Quick checklist

- [ ] `monkeyc -o build/app.prg -d instinct2 -f monkey.jungle` prints `BUILD SUCCESSFUL`.
- [ ] `build/app.prg` exists.
- [ ] Watch is connected via USB and mounts as `/Volumes/GARMIN`.
- [ ] `app.prg` copied to `/Volumes/GARMIN/GARMIN/Apps/`.
- [ ] `APP.TXT` created in `/Volumes/GARMIN/GARMIN/Apps/LOGS/` (uppercase; watch FAT is case-sensitive).
- [ ] Watch ejected safely.
- [ ] App appears in the activities list after pressing **START**.
- [ ] App launches without showing **"IQ!"**.

## Publishing to Connect IQ Store (Beta)

To make custom FIT lap fields visible in Garmin Connect (height,
length, airtime, accel height), publish the app as a private beta
and install it via the Connect IQ mobile app.

1. **Export the `.iq` package** — in VS Code run
   **Monkey C: Export Project**. The output (`KiteTracker.iq` or
   similar) lands in the project root.
2. **Create the app entry** — sign in to
   [Garmin Developer Portal](https://developer.garmin.com/connect-iq/),
   click **My Apps** → **New App**, fill in name / version / support
   info. The app type is **Watch App** and the only product is
   **Instinct Solar 2 (instinct2)**.
3. **Upload the binary** — in the app's **Distribution** tab, upload
   the `.iq` file. Set status to **Beta**.
4. **Invite yourself** — under **Beta Testers** add your own Garmin
   Connect account email.
5. **Install from the phone** — open Garmin Connect on your phone,
   tap **More** → **Settings** → **Connect IQ Store** → **My Apps**.
   The beta app appears there; install it.
6. **Record and sync** — open Kite Tracker on the watch, record a
   session, end it, and sync the watch with the phone. The activity
   will show up in Garmin Connect with the custom lap fields visible
   (you may need to scroll right in the lap view).

The app id in `manifest.xml` must remain constant across builds, or
the store will treat the new version as a different app.
