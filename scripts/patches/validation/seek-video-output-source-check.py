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
    ('src/input/decoder.c', 'only video bootstrap asks input for data',
     r'if \(p_owner->cat == VIDEO_ES\s*&& \(p_owner->frames_countdown > 0 \|\| p_owner->paused_seek_pending\)\)'),
    ('src/input/decoder.c', 'only video clears frame-step input demand',
     r'if \(p_owner->cat == VIDEO_ES\s*&& vlc_fifo_IsEmpty\(p_owner->p_fifo\)\s*&& \(p_owner->frames_countdown > 0 \|\| p_owner->paused_seek_pending\)\)\s*decoder_Notify\(p_owner, frame_next_need_data, false\);'),
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
    ('src/input/decoder.c', 'paused seek first picture waits for the buffering clock reset',
     r'if\( p_owner->b_first && p_owner->b_waiting && !p_owner->paused_seek_pending \)'),
    ('src/input/decoder.c', 'resume releases the paused output before decoder acknowledgement',
     r'p_owner->pause_date = i_date;\s*if \(!b_paused && p_owner->output_paused && p_owner->cat == VIDEO_ES\)\s*Decoder_ChangeOutputPause\(p_owner, false, i_date\);\s*p_owner->frames_countdown = 0;'),
    ('src/clock/clock.c', 'clock reset retains a live pause origin',
     r'main_clock->wait_sync_ref_priority = UINT_MAX;\s*if \(!main_clock->paused\)\s*main_clock->pause_date = VLC_TICK_INVALID;\s*vlc_cond_broadcast\(&main_clock->cond\);'),
    ('src/clock/clock.c', 'paused fallback uses the frozen clock origin',
     r'if \(main_clock->paused\)\s*now = main_clock->pause_date;\s*if \(clock->priority < main_clock->wait_sync_ref_priority'),
    ('src/input/decoder.c', 'decoder startup shares the frozen buffering origin',
     r'vlc_clock_Start\(p_owner->p_clock,\s*p_owner->paused \? p_owner->pause_date : vlc_tick_now\(\),\s*date\);'),
    ('modules/codec/videotoolbox/decoder.c', 'H264 tracks recovery picture order',
     r'if \(p_sys->sync_state == STATE_BITSTREAM_WAITING_RAP\s*&& p_info->b_keyframe\)\s*h264ctx->recovery_poc = p_info->i_poc;\s*p_info->b_leading = p_sys->sync_state == STATE_BITSTREAM_DISCARD_LEADING\s*&& p_info->i_poc < h264ctx->recovery_poc;'),
    ('modules/codec/videotoolbox/decoder.c', 'H264 reset is captured before recovery state advances',
     r'const bool reset_decoder = p_dec->fmt_in->i_codec == VLC_CODEC_H264\s*&& p_sys->sync_state == STATE_BITSTREAM_WAITING_RAP;\s*if \(p_sys->sync_state == STATE_BITSTREAM_WAITING_RAP\)'),
    ('modules/codec/videotoolbox/decoder.c', 'recovery sample carries Apple decoder reset attachment',
     r'if \(reset_decoder\)\s*CMSetAttachment\(sampleBuffer,\s*kCMSampleBufferAttachmentKey_ResetDecoderBeforeDecoding,\s*kCFBooleanTrue, kCMAttachmentMode_ShouldNotPropagate\);\s*pic_pacer_WaitAllocatableSlot'),
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
