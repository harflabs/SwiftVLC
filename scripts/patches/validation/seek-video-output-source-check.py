#!/usr/bin/env python3
"""Check the output authority and paused-bootstrap boundaries of extension 12.

These structural guards complement the decoded-pixel runtime tests. Every guard
is mutation-checked so a detached marker or a missing stage cannot pass silently.
"""
import re
import sys
from pathlib import Path

CHECKS = (
    ('src/libvlccore.sym', 'shared core timer entry point is exported',
     r'(?m)^vlc_player_AddTimerWithVideoOutput$'),
    ('src/input/decoder.c', 'EOF retires paused bootstrap and transfers the last picture',
     r'owner->paused_seek_pending = false;\s*if \(owner->seek_last_picture != NULL\)\s*\{\s*picture_t \*last = owner->seek_last_picture;\s*owner->seek_last_picture = NULL;\s*owner->seek_display_time = VLC_TICK_INVALID;\s*owner->i_preroll_end = PREROLL_NONE;\s*\(void\) ModuleThread_PlayVideo\(owner, last\);'),
    ('src/input/decoder.c', 'separate paused bootstrap',
     r'p_owner->paused_seek_pending = p_owner->paused && cat == VIDEO_ES;'),
    ('src/input/decoder.c', 'bootstrap runs without an explicit frame request',
     r'p_owner->paused && p_owner->frames_countdown == 0\s*&& !p_owner->paused_seek_pending\s*&& !p_owner->b_draining'),
    ('src/input/decoder.c', 'bootstrap asks input for data',
     r'if \(p_owner->frames_countdown > 0 \|\| p_owner->paused_seek_pending\)'),
    ('src/input/decoder.c', 'presentation threshold rejects early pictures',
     r'if \(p_owner->seek_display_time != VLC_TICK_INVALID\s*&& p_picture->date < p_owner->seek_display_time\)\s*\{\s*if \(p_owner->seek_last_picture != NULL\)\s*picture_Release\(p_owner->seek_last_picture\);\s*p_owner->seek_last_picture = p_picture;\s*return VLC_SUCCESS;\s*\}'),
    ('src/input/es_out.c', 'replacement decoder inherits presentation threshold',
     r'vlc_input_decoder_SetSeekDisplayTime\(dec, p_sys->i_preroll_end\);'),
    ('src/input/es_out.c', 'seek updates existing video decoder threshold',
     r'vlc_input_decoder_SetSeekDisplayTime\(es->p_dec, i_date\);'),
    ('src/video_output/video_output.c', 'only proven submission captures output',
     r'vlc_tick_t drift = !submission_unproven\s*\? vlc_clock_UpdateVideoFrameStep'),
    ('src/player/input.c', 'output is normalized before notification',
     r'capture->valid = vlc_player_NormalizeOutputClockPoint\([^;]+;\s*if \(capture->valid\)\s*vlc_player_NotifyVideoOutput'),
    ('src/player/timer.c', 'seeking and stopping suppress output notification',
     r'if \(!player->timer.stopping && !player->timer.best_source.seeking\)'),
    ('modules/demux/mp4/mp4.c', 'edit offset also applies before first DTS',
     r'if\( edit->i_media_time > 0 \)\s*i_time -= edit->i_media_time;'),
    ('modules/demux/adaptive/PlaylistManager.cpp', 'invalid origin cannot become zero',
     r'cached.i_normaltime = VLC_TICK_INVALID;\s*if \(startTimes.continuous != VLC_TICK_INVALID &&\s*startTimes.segment.media != VLC_TICK_INVALID\)'),
    ('modules/demux/adaptive/plumbing/FakeESOut.cpp', 'video origin uses presentation time',
     r'const vlc_tick_t origin = es_id->esType\(\) == EsType::Video &&\s*p_block->i_pts != VLC_TICK_INVALID\s*\? p_block->i_pts : p_block->i_dts;'),
)

def check(sources):
    for path, label, pattern in CHECKS:
        count = len(tuple(re.finditer(pattern, sources[path])))
        if count != 1:
            raise ValueError(f'{label}: expected one connected code fragment, found {count}')

def main():
    root = Path(sys.argv[1])
    sources = {path: re.sub(r'/\*.*?\*/|//[^\n]*', '', (root / path).read_text(), flags=re.S)
               for path, _, _ in CHECKS}
    check(sources)
    for path, label, pattern in CHECKS:
        mutated = dict(sources)
        mutated[path] = re.sub(pattern, '', mutated[path], count=1)
        try:
            check(mutated)
        except ValueError:
            continue
        raise ValueError(f'mutation escaped: {label}')
    print(f'PASS seek video-output source contract ({len(CHECKS)} guards and mutations)')

if __name__ == '__main__':
    main()
