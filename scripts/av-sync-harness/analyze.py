#!/usr/bin/env python3
"""Analyze avh samples: on-screen frame vs VLC audio clock.

Usage: analyze.py samples.jsonl [--fps 30] [--json out.json]

Per sample: video_pts = frame/fps (seconds), audio = player time (s),
offset = video_pts - audio.  In sync, offset sits in [-1/fps, 0] (+ constant
pipeline bias).  A "stall" is a run where the displayed frame does not change
for > STALL_MS while VLC is in Playing state and the audio clock advances.
"""
import json
import statistics
import sys

path = sys.argv[1]
fps = 30.0
if "--fps" in sys.argv:
    fps = float(sys.argv[sys.argv.index("--fps") + 1])
out_json = None
if "--json" in sys.argv:
    out_json = sys.argv[sys.argv.index("--json") + 1]
STALL_MS = 150
PLAYING = 3

samples, marks, stats, events = [], [], [], []
with open(path) as fh:
    for line in fh:
        try:
            o = json.loads(line)
        except ValueError:
            continue
        k = o.get("k")
        if k == "s":
            samples.append(o)
        elif k == "m":
            marks.append(o)
        elif k == "x":
            stats.append(o)
        elif k == "e":
            events.append(o)

if not samples:
    print("no samples")
    sys.exit(1)
t0 = samples[0]["t"]


def rel(t):
    return (t - t0) / 1e6


def valid(s):
    return s["f"] >= 0 and s["a"] >= 0


# --- stalls -----------------------------------------------------------------
# A stall is a run of Playing samples that show one frame while the audio clock
# advances. Runs split at frame changes and at playback-state transitions, so a
# pause is never counted and a freeze after resume starts at the resume.
stalls = []
run = []


def close_run(open_ended=False):
    if len(run) < 2:
        return
    first, last = run[0], run[-1]
    dur = (last["t"] - first["t"]) / 1000.0
    adv = last["a"] - first["a"]
    if dur > STALL_MS and adv > STALL_MS * 0.8:
        stall = {"start": rel(first["t"]), "dur_ms": round(dur), "audio_adv_ms": adv, "frame": first["f"]}
        if open_ended:
            stall["open_ended"] = True
        stalls.append(stall)


for s in samples:
    playing = valid(s) and s["st"] == PLAYING
    if run and (not playing or s["f"] != run[-1]["f"]):
        close_run()
        run = []
    if playing:
        run.append(s)
close_run(open_ended=True)


# --- offsets per phase ---------------------------------------------------------
def offsets(t_from, t_to):
    vals = []
    for s in samples:
        if t_from <= s["t"] < t_to and valid(s) and s["st"] == PLAYING:
            vals.append(s["f"] / fps - s["a"] / 1000.0)
    return vals


def summarize(vals):
    if not vals:
        return None
    vals = sorted(vals)
    return {
        "n": len(vals),
        "median_ms": round(statistics.median(vals) * 1000, 1),
        "p05_ms": round(vals[int(0.05 * (len(vals) - 1))] * 1000, 1),
        "p95_ms": round(vals[int(0.95 * (len(vals) - 1))] * 1000, 1),
        "min_ms": round(vals[0] * 1000, 1),
        "max_ms": round(vals[-1] * 1000, 1),
    }


def frames_shown(t_from, t_to):
    seen = set()
    for s in samples:
        if t_from <= s["t"] < t_to and s["f"] >= 0:
            seen.add(s["f"])
    return len(seen)


report = {"file": path, "samples": len(samples), "duration_s": round(rel(samples[-1]["t"]), 2),
          "stalls": stalls, "resumes": [], "shows": []}

ready = next((m for m in marks if m["n"] == "playing_ready"), None)
first_req = next((m for m in marks if m["n"] in ("pause_req", "hide_req")), None)
if ready:
    end = first_req["t"] if first_req else samples[-1]["t"]
    report["baseline"] = summarize(offsets(ready["t"] + 1_000_000, end))

# Resume analysis: pre-pause offset, time to first new frame, post-resume offset.
for i, m in enumerate(marks):
    if m["n"] not in ("resume_req", "show_req"):
        continue
    pause = next((p for p in reversed(marks[:i]) if p["n"] in ("pause_req", "hide_req")), None)
    nxt = next((p for p in marks[i + 1:] if p["n"] in ("pause_req", "hide_req", "done")), None)
    t_end = nxt["t"] if nxt else samples[-1]["t"]
    pre = summarize(offsets(pause["t"] - 3_000_000, pause["t"])) if pause else None
    # First frame change after resume.
    base_frame = None
    first_new = None
    for s in samples:
        if s["t"] < m["t"]:
            if s["f"] >= 0:
                base_frame = s["f"]
            continue
        if s["f"] >= 0 and base_frame is not None and s["f"] != base_frame:
            first_new = s
            break
    post_early = summarize(offsets(m["t"] + 500_000, m["t"] + 2_000_000))
    post_late = summarize(offsets(t_end - 3_000_000, t_end))
    win_stalls = [st for st in stalls if rel(m["t"]) <= st["start"] < rel(t_end)]
    entry = {
        "event": m["n"], "at_s": round(rel(m["t"]), 3), "pause_s": m.get("d"), "cycle": m.get("cycle"),
        "how": m.get("how"),
        "time_to_new_frame_ms": round((first_new["t"] - m["t"]) / 1000) if first_new else None,
        "pre_offset": pre, "post_offset_0.5-2s": post_early, "post_offset_last3s": post_late,
        "frames_shown_after": frames_shown(m["t"], t_end),
        "expected_frames_after": round((t_end - m["t"]) / 1e6 * fps),
        "stalls_after": win_stalls,
    }
    report["resumes"].append(entry)

# Whole-run offset drift (per 10 s window) for long runs.
if ready:
    windows = []
    t = ready["t"] + 1_000_000
    last = samples[-1]["t"]
    while t < last:
        smm = summarize(offsets(t, t + 10_000_000))
        if smm:
            windows.append({"at_s": round(rel(t), 1), "median_ms": smm["median_ms"], "p95_ms": smm["p95_ms"]})
        t += 10_000_000
    report["windows"] = windows

# Final VLC statistics.
if stats:
    last = stats[-1]
    report["vlc_stats_final"] = {k: last.get(k) for k in
                                 ("dec_v", "disp", "late", "lost", "dec_a", "play_a", "lost_a", "disc", "corrupt",
                                  "r_status", "r_ready", "r_flush", "r_err")}
    nonready = [round(rel(x["t"]), 2) for x in stats if x.get("r_ready") is False]
    failed = [round(rel(x["t"]), 2) for x in stats if x.get("r_status") == 2]
    report["renderer_not_ready_at"] = nonready[:50]
    report["renderer_failed_at"] = failed[:50]

if out_json:
    with open(out_json, "w") as fh:
        json.dump(report, fh, indent=1)

# Human summary.
print(f"file={path} samples={len(samples)} dur={report['duration_s']}s")
if report.get("baseline"):
    b = report["baseline"]
    print(f"baseline offset: median {b['median_ms']} ms  p05 {b['p05_ms']}  p95 {b['p95_ms']}")
print(f"stalls >{STALL_MS}ms while playing: {len(stalls)}")
for st in stalls[:40]:
    print(f"  stall at {st['start']:.2f}s  {st['dur_ms']} ms  (audio +{st['audio_adv_ms']} ms) frame {st['frame']}"
          + ("  OPEN-ENDED" if st.get("open_ended") else ""))
for r in report["resumes"]:
    pe = r["post_offset_0.5-2s"]
    pl = r["post_offset_last3s"]
    pr = r["pre_offset"]
    print(f"{r['event']} @{r['at_s']}s pause={r['pause_s']} how={r['how']}: new frame after {r['time_to_new_frame_ms']} ms; "
          f"offset pre {pr and pr['median_ms']} -> early {pe and pe['median_ms']} -> late {pl and pl['median_ms']} ms; "
          f"frames {r['frames_shown_after']}/{r['expected_frames_after']}; stalls {len(r['stalls_after'])}")
if report.get("vlc_stats_final"):
    print("vlc stats:", report["vlc_stats_final"])
if report.get("renderer_not_ready_at"):
    print("renderer not ready at:", report["renderer_not_ready_at"][:20])
if report.get("renderer_failed_at"):
    print("renderer FAILED at:", report["renderer_failed_at"][:20])
