# Jump detection: false >8 m jumps — investigation and adversarial review

Analysis of two sessions on 2026-10-10 that recorded ~25 jumps each, of
which the tall ones (>8 m) are known false. The rider's real jumps top out
around 5 m. This is **v2**: the original findings were re-derived with a
corrected FIT-lap-to-jump mapping and re-examined adversarially; several
v1 claims did not survive and are retracted in §3.

> Derived from the shipped artifact on the watch (HEAD `e2e89c2`), the
> session FIT files in `/Volumes/GARMIN/GARMIN/Activity/`, and the
> on-device text logs in `/Volumes/GARMIN/GARMIN/Apps/LOGS/`.

---

## Implementation status (2026-10-10, post-v2)

Implemented in the working tree and validated by the unit suite
(26/26 PASS, incl. 4 new gate tests):

- **F1** — `raw_pressure` / `accel_g` as FIT record developer fields
  (`SessionManager.mc`, ids 3/4), plus a per-candidate `CAND baro`
  diagnostic log line from the detector.
- **F2** — takeoff refinement now runs **before** the dip/height search;
  height, airtime and GPS length share one window.
- **F3** — candidate windows are clamped past the previous candidate's
  validation windows (clean: previous landing; discarded: previous
  landing + `PENDING_MS`).
- **F4** — baseline flatness (`BASELINE_MAX_SPREAD_PA` = 40).
- **F5** — sustained dip (≥2 samples within `DIP_SUSTAIN_BAND_PA` = 20)
  and dip rate cap (`BARO_MAX_DIP_RATE_PA_S` = 200).
- **F6** — height/airtime kinematic absurdity gate
  (`ABSURD_VEL_MPS` = 25).
- **F7** — sideloads now build for `instinct2x` (the actual watch).
- **F9** — lap fields are zeroed before session stop (no phantom
  trailing-lap duplicate).

F8 (height ceiling) remains rejected by the field owner. Sub-1 s hops
are out of scope (barometer cannot validate them; see the v2 discussion
of sampling physics).

The 2026-10-10 replay expectations: the 14.9 m event is rejected by the
rate gate, the 10.0 m/3.68 s event by flatness/contamination clamps, and
the 8.5 m burst events by the previous-event clamp. Real 2–6 m jumps
with clean baselines are unaffected (all legacy replay tests pass
unchanged in intent).

## Field validation (2026-10-11 session, first build with the gates)

- 19 jumps recorded, heights **1.5–4.9 m — zero >8 m false positives**.
- Record telemetry fields work end-to-end: 2290 `raw_pressure` samples
  (~1 Hz) and 2289 `accel_g` samples in the FIT.
- **Accelerometer gravity question settled**: `accel_g` ≈ 1.10 G at
  rest → gravity IS included in the stream; the earlier low `minG`
  values were real flight physics, not broken data (§3.3 stands).
- The wet port was active this session (2 raw samples above 105 kPa,
  11 above 102 kPa) and the new gates absorbed the events around them
  (`unstableBaseline spread=440` in APPDEV.TXT).
- F9 confirmed: the trailing FIT lap now reads 0/0/0 instead of
  duplicating the last jump.
- Known remaining issue: airtime inflation persists (three jumps with
  6.9–7.4 s airtime at 1.9–2.5 m height) — cosmetic for now, flagged
  for the next tuning pass with the new telemetry data.

## Airtime ceiling (2026-10-12, after field feedback)

The rider confirmed the 4.97–7.36 s "airtimes" (jumps 12/17/18/19 of
the 2026-10-11 session) are invalid. Added `MAX_AIRTIME_MS = 4500`
(4500 rather than the literal 5000 so the 4.97 s detection is also
rejected; longest valid jump that session was 3.51 s — tune freely).
Candidates whose refined airtime exceeds it discard with
`longFlight` before the dip search runs. Validated by
`testLongAirtimeDiscarded` / `testAirtimeUnderCeilingRecords` (28/28
suite).

## Session summary bug (2026-10-11 report, fixed same day)

Exiting via BACK while recording (`onStop`) saved the FIT but ran no
`_dumpSession()` and could not push the review view — hence "no summary
after stop". Fix: `onStop` now dumps the session block; the summary is
persisted to `Application.Storage` on every stop path; the start screen
shows "Last: N jumps · Xs air" and UP/DOWN opens the stored
SessionReviewView.

---

## 0. What changed in v2

| v1 claim | verdict |
|---|---|
| "No speed/heading/HR/altitude correlate" | **Redone** — v1 used a wrong lap↔jump alignment (§3.1). Redone correctly, the conclusion still holds, but it was luck, not rigor. |
| False events are "slow 5–8 s barometric drifts" | **Retracted** (§3.2) — the 14.9 m event's dip began late and fast; device-altitude evidence was misaligned and is contradictory anyway. |
| "Accelerometer broken / gravity excluded" | **Downgraded to unconfirmed** (§3.3) — kite-lift physics explains the low G values; the counter-evidence was weak. |
| "0-jump sessions explained by the GPS speed gate" | **Downgraded to hypothesis** (§3.4) — no logs survive from those sessions. |
| — | **New** (§4.1): height and airtime are computed over *different* time windows — a concrete code flaw. |
| — | **New** (§4.2): the false >8 m events are late members of detection "bursts"; window contamination from the previous event is a plausible mechanism. |

---

## 1. Critical unresolved ambiguity (read this first)

The original complaint was *"I've seen like over 20 jumps when I've done
a couple"*. Later input was *"there for sure hasn't been jump over 8 m,
the rest seems valid"*. These conflict: if only a couple of real jumps
happened, then the 1.5–3 m detections (the bulk of the 25) are false too,
and the problem is the **whole detector**, not the >8 m outliers.

The detections are spaced 5–60 s apart over ~20 minutes, in bursts of
2–5 events 5–12 s apart (§4.2). That cadence is consistent with *either*
a rider deliberately jumping every ~30 s, *or* periodic riding events
(chop, carves, small hops) each passing the gates. The FIT cannot tell
these apart. **Decide this before choosing a fix** — the fix for "outlier
heights" (§5 F4–F6) is very different from the fix for "detector fires
on riding" (dip threshold / gate redesign).

---

## 2. Confirmed facts

| item | value |
|---|---|
| Device | **Instinct 2X Solar** (`Debug/ERR_LOG.BAK`: "4394 (Instinct 2X Solar)"), fw 17.11, CIQ 6.0.2 |
| App on watch | `GARMIN/Apps/appdev.prg` = **HEAD `e2e89c2`** (contains the `DISCARD_TALLY` string, HEAD-only) |
| Build target | `build.sh --dev` compiles with `-d instinct2`, but the watch is an **instinct2x** (both are in the manifest). It runs, but every sensor-behaviour assumption in the docs was written for the Instinct 2. See §5 F7. |

| FIT file | laps | unique jumps | notes |
|---|---|---|---|
| `2026-10-10-13-04-39.fit` (s113) | 25 | 24 | last lap is a phantom duplicate |
| `2026-10-10-14-32-01.fit` (s125) | 26 | 25 | `APPDEV.TXT` ends `jumps=25` |

**Lap↔jump mapping (used throughout v2):** `setData` runs immediately
before `addLap()`, and `addLap()` *closes* the current lap. So lap *i*
carries the metrics of jump *i+1*, and that jump's landing is ≈
`lap[i+1].start_time − ~3 s` (PENDING_MS 2600 + up to one 1 s accel batch).
Lap 0 carries jump 1; the trailing lap repeats the last `setData` values.

Heights per session (m), false ones (>8 m) in bold:

- s113: 2.0, 1.9, 1.6, 3.3, 1.7, 2.1, 3.3, 1.5, 1.8, 2.1, 5.2, 4.1, 4.6,
  3.1, 2.5, 3.3, 4.7, 3.3, **8.5**, 4.4, 2.6, **9.9**, 5.4, **9.8**,
  **9.8***(dup)*
- s125: 1.5, 2.7, 2.1, 4.0, 1.8, 3.1, 1.6, 5.5, 1.8, 2.9, 5.7, 4.4, 2.2,
  4.8, **10.0**, 5.9, 2.0, 2.0, 3.4, 4.8, 2.3, 1.9, 3.6, **14.9**,
  **8.5**, **8.5***(dup)*

There is a clean numeric gap: valid-looking detections reach **5.9 m**,
false ones start at **8.5 m** (≈100 Pa dip).

The false events, correctly aligned:

| session | landing (UTC) | h (m) | air (s) | len (m) | gap to prev jump | burst position |
|---|---|---|---|---|---|---|
| s113 | ~11:25:13 | 8.5 | 1.36 | 6.5 | 17 s | (not in a burst) |
| s113 | ~11:26:06 | 9.9 | 1.56 | 10.7 | 7 s | burst [19–23], event #3 |
| s113 | ~11:26:29 | 9.8 | 2.15 | 11.8 | 11 s | burst [19–23], event #5 |
| s125 | ~12:42:48 | 10.0 | 3.68 | 23.1 | 9 s | burst [13,14], last |
| s125 | ~12:48:23 | 14.9 | 0.80 (capped) | 7.2 | 7 s | burst [22–24], #2 of 3 |
| s125 | ~12:48:28 | 8.5 | 2.13 | 12.7 | 5 s | burst [22–24], last |

---

## 3. Review corrections

### 3.1 v1's lap↔jump alignment was wrong

v1 correlated each lap's metrics against a window around
`lap.start_time`. Given the mapping in §2, that window actually covered
the *previous* jump's flight/landing, offset by ~3 s and one inter-jump
gap. All v1 "no correlation" analyses were therefore misaligned. Redone
with correct alignment (windows = [landing − airtime, landing] ± 2 s):

- **GPS speed**: false events 1.9–6.6 m/s min/avg — same range as valid.
- **Heading change, heart rate**: no separation.
- **Device barometric altitude** (FIT `enhanced_altitude`): flight-window
  Δ of 0.0–5.4 m for false events vs 0.0–6.4 m (one 11.0 m) for valid —
  no separation, and see §3.2 for why it cannot arbitrate anyway.

The conclusion (no FIT-level discriminator) survives, but only after
being redone properly.

### 3.2 The "slow barometric drift" story is retracted

v1 claimed the false events coincided with slow 5–8 m altitude swings
over 5–13 s. With correct alignment those swings sit *outside* the false
events' flight windows — the claim was an artifact of the misalignment.

What the data actually says about the 14.9 m event: its reported airtime
is **exactly** the `MIN_FLIGHT_MS` floor (0.80 s), which only happens
when the refinement's `capTs` clamps it
(`source/JumpDetector.mc:602-604`). That means the first pressure sample
≥ `DIP_START_PA` below baseline was found **within 0.8 s of landing** —
i.e. the ~180 Pa excursion began late and *fast*, a transient, not a
slow drift. The second-lowest-sample guard did not reject it, so either
≥2 samples were low or the flight window held very few samples.

During the s125 12:48 burst the device's fused altitude moved **opposite**
to the app's claimed dip (device alt fell ~5 m — pressure *rising* —
across the event where the app recorded a 180 Pa pressure *fall*). The
device altitude is GPS-fused and ~1 Hz, so it cannot arbitrate between
"the raw pressure really dipped" and "the baseline was contaminated".
Both stories fit.

### 3.3 "Accelerometer broken / gravity excluded" is unconfirmed

v1 argued that `minG` values of 0.05–0.3 and `lowCount` of up to half the
window imply the streaming accelerometer excludes gravity. Challenge:
**kite lift unweights the rider**. During a real kite jump the total-G
sits well below 1 G for most of the flight, so `lowCount` high and low
`minG` are consistent with *correct, gravity-included* data from real
flights. The counter-evidence (old poll-path session showing `minG` of
1.09–1.46) came from a session with **zero** jumps recorded and a
snapshot poller re-reading one ~1 Hz value — i.e. stale data, not a
calibration reference.

The question stays open (`ACCEL_STATS` from a fresh run would settle it),
but v1's "the accel gates are meaningless" claim is not supported.

### 3.4 "0-jump sessions = GPS speed gate" is a hypothesis, not a finding

The sessions from 2026-09-22 … 2026-10-08 recorded 0 jumps, and v1
attributed this to the GPS speed gate reading 0.1–0.7 m/s. Those numbers
come from the *tail of the 2026-10-10 session* (rider low on speed at the
end). No logs survive from the 0-jump sessions themselves; they may equally
have had no wind, no riding, or a different failure. Hypothesis only.

---

## 4. New findings

### 4.1 Height and airtime are computed over different windows (code flaw)

In `_maybeCompletePending`:

1. the flight dip / height search runs over
   `(pre-refinement _pendTakeoffTs, _pendLandingTs]`
   (`source/JumpDetector.mc:512-543`);
2. **afterwards**, the takeoff refinement mutates `_pendTakeoffTs` and
   `_pendAirtimeMs` (`source/JumpDetector.mc:587-612`);
3. `_recordJump` then anchors the GPS length to the **refined** takeoff.

So the reported height, airtime, and length each describe different time
intervals. Visible consequences in the data:

- `airtime == 0.80` appears verbatim 4 times (the `MIN_FLIGHT_MS` cap
  manufacturing values) — e.g. a 4.8 m "jump" with 0.80 s airtime and a
  14.9 m one with 0.80 s.
- Valid jumps show physically impossible height-for-airtime (e.g. 4.8 m
  in 1.10 s, 4.79 m in 0.80 s) *because* the height window is wider than
  the airtime window. This is exactly why a ballistic plausibility gate
  cannot be used today (it would cut valid jumps, see §5 F6).

### 4.2 The false >8 m events are late members of detection bursts

Grouping jumps whose landings are ≤12 s apart:

| session | burst | heights | gaps (s) | contains false |
|---|---|---|---|---|
| s113 | [0–4] | 2.0, 1.9, 1.6, 3.3, 1.7 | 9, 7, 10, 7 | no |
| s113 | [7, 8] | 1.5, 1.8 | 4 | no |
| s113 | [10, 11], [12, 13], [15–17] | … | 9 / 6 / 12, 8 | no |
| s113 | [19–23] | 4.4, 2.6, **9.9**, 5.4, **9.8** | 12, 7, 12, 11 | **yes** |
| s125 | [3–5], [6–10], [11, 12], [15, 16], [18, 19] | … | 3–11 | no |
| s125 | [13, 14] | 4.8, **10.0** | 9 | **yes** |
| s125 | [22–24] | 3.6, **14.9**, **8.5** | 7, 5 | **yes** |

- 5 of 6 false events have a previous landing ≤11 s away; 3 of 6 are the
  *last* event of a burst.
- The candidate windows span ~12 s of pressure history: baseline
  `[takeoff−4000, takeoff−500]` (`source/JumpDetector.mc:122-123`) plus a
  flight window up to `MAX_FLIGHT_MS` = 8 s. The observed inter-jump gaps
  (5–12 s) are *shorter* than that, so the previous event's pressure
  excursion can sit inside the next candidate's baseline or flight window.
- Candidate mechanisms (unproven, both fit §3.2's contradiction):
  - baseline biased by the previous event's excursion/recovery → dip
    inflated;
  - the previous event's trough captured as this flight's second-lowest
    sample.
- **Not sufficient**: valid jumps also land 3–9 s apart, and bursts
  contain valid events. Contamination is at best a contributing factor.

### 4.3 The source separation is thin

The one false event with surviving numbers had `peakDeltaPa=101`
(8.49 m). A plausible real 5–6 m jump is a ~60–70 Pa dip. The false and
true populations are only ~1.5× apart at the dip level — any fix that is
a plain threshold on the dip will be fragile. This is why §5 prefers
shape/consistency gates over magnitude caps.

### 4.4 Kept from v1

- The trailing FIT lap duplicate (s125 24≡25, s113 23≡24): Garmin's
  auto-closed trailing lap keeps the previous `setData` values. Cosmetic;
  the app's own count is correct.
- The raw pressure/accel series for the false events rotated out of
  `APP.TXT` (rotates at a few KB) and is absent from the FIT — the exact
  excursion shapes are unrecoverable.

---

## 5. Fix proposals (ranked)

### F1 — Capture the raw signals (do first, unchanged, now more specific)

Add Connect IQ **record** developer fields via
`session.createField(..., MESG_TYPE_RECORD)`:

- `raw_pressure_pa` — `Activity.getActivityInfo().rawAmbientPressure`
- `accel_g` — `sqrt(x²+y²+z²)/9.80665` from the accel callback

Additionally log per *candidate* (one line, survives rotation long
enough): baseline-window min/median/max, flight-window sample count,
dipStart timestamp, and whether the refinement cap fired. This
distinguishes §4.2's mechanisms directly.

### F2 — Make height, airtime, and length use the same window

Reorder `_maybeCompletePending`: run the takeoff refinement **before**
the dip/height search, and search the dip within `(dipStart, landing]`.
The baseline still uses the pre-refinement takeoff (it should sample the
pre-jump riding level). This makes the three metrics describe one
interval, stops the `MIN_FLIGHT_MS` cap from manufacturing airtime, and
is a prerequisite for any consistency gate (F6). Low risk: the dip search
window shrinks, so some marginal candidates lose a few Pa of dip.

### F3 — Bound candidate windows by the previous event

Clamp the baseline-window start and the flight-window start to after the
previous event's landing (+ PENDING), i.e. never let one candidate's
pressure windows overlap the previous candidate's excursion. Cheap, low
risk (genuine back-to-back jumps within 5 s are rare, and a landing-
triggered detector does not need 12 s of pre-history then).

### F4 — Baseline flatness gate

Reject (or re-compute the baseline from a longer window) when the
baseline window's `max − min` exceeds a threshold. A window contaminated
by the previous event's excursion is not flat. Tunable after F1's data.

### F5 — Sustained-dip / slew-rate gate

Require the dip to be *sustained* (≥2 samples within a band around the
minimum) and/or cap the pressure slew rate (Pa per 100 ms). The 14.9 m
event implies ~180 Pa inside 0.8 s (~37 m/s equivalent vertical), far
beyond any real jump. Data-dependent; tune after F1.

### F6 — Height/airtime absurdity gate (only after F2)

With F2 in place, reject height-for-airtime combos implying impossible
vertical speeds (e.g. mean |v| > ~25 m/s). Catches 14.9 m/0.8 s; does
**not** catch 8.5 m/2.1 s. Partial; combine with F3/F4.

### F7 — Build for the actual device

`build.sh --dev` compiles `-d instinct2`; the watch is an Instinct 2X
Solar. Build sideloads with `-d instinct2x` (the manifest already lists
it) so sensor behaviour matches the target hardware.

### F8 — Height ceiling (rejected)

A hard cap (~8 m) removes exactly the observed false events but was
rejected by the field owner (future higher jumps must not be clipped).
Documented for completeness.

### F9 — Trailing-lap duplicate (cosmetic)

Zero the custom lap fields before session stop, or accept the extra
duplicated lap in the FIT.

---

## 6. Reproduction

```sh
python3 -m venv fitenv && ./fitenv/bin/pip install fitparse
```

Key detail: **map lap *i* to jump *i+1*** and place the landing at
`lap[i+1].start_time − 3 s` (see §2). Analysis scripts used (fitparse):

- per-jump table: heights/airtimes/lengths from `lap` messages
- corrected correlation: records within `[landing − airtime, landing] ± 2 s`
- bursts: group landings with gaps ≤ 12 s

Pull the on-device logs while the watch is mounted:

```sh
ls /Volumes/GARMIN/GARMIN/Apps/LOGS/          # APPDEV.TXT / APPDEV.BAK
cp /Volumes/GARMIN/GARMIN/Apps/LOGS/APPDEV.TXT ./APPDEV.TXT
```

Confirm the running build matches HEAD:

```sh
strings /Volumes/GARMIN/GARMIN/Apps/appdev.prg | grep DISCARD_TALLY
```

---

## 7. Open questions

1. **Did the rider actually do ~20 jumps, or a couple?** (§1 — decides
   whether we fix outliers or the whole detector. The burst structure is
   compatible with both.)
2. Does this device's `Sensor.SensorData.accelerometerData` include
   gravity, and what do `ACCEL_STATS` (n, minG, maxG, below090) look like
   on a live session?
3. What is the raw pressure series during a false >8 m event — a fast
   late transient (per §3.2) or a contaminated baseline (per §4.2)?
4. How flat is the barometer before a real jump vs before a false event
   that follows another jump by ≤11 s? (Decides F4's threshold.)
5. Why did the 2026-09-22 … 2026-10-08 sessions record zero jumps? (§3.4 —
   no logs survive; could be weather, the speed gate, or something else.)
