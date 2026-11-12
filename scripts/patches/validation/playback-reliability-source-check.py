#!/usr/bin/env python3
"""Check the playback-reliability patches 0055-0071 in a patched VLC tree.

Each guard is one connected code fragment and is mutation-checked, so a patch
that is dropped, reverted or only partly applied cannot pass silently.
"""
import re
import sys
from pathlib import Path

CHECKS = (
    ('src/clock/clock.c', '0055 resume shifts every clock context',
     r'vlc_list_foreach\(ctx, &main_clock->prev_contexts, node\)\s*context_resume\(ctx, delay\);\s*'
     r'context_resume\(main_clock->context, delay\);'),
    ('src/clock/clock.c', '0055 resume shifts the last conversion of each clock',
     r'if \(clock->last_conversion != VLC_TICK_INVALID\)\s*clock->last_conversion \+= delay;'),
    ('src/input/es_out.c', '0055 the main clock resumes before the input clock',
     r'vlc_clock_main_ChangePause\(pgrm->clocks\.main, i_date, b_paused\);\s*'
     r'vlc_clock_main_Unlock\(pgrm->clocks\.main\);\s*if \(!b_paused\)\s*'
     r'input_clock_ChangePause\(pgrm->p_input_clock, b_paused, i_date\);'),
    ('modules/video_output/apple/VLCSampleBufferDisplay.m', '0056 queued presentation time is tracked',
     r'rendererQueuedHostTime =\s*fmax\(rendererQueuedHostTime, CMTimeGetSeconds\(pts\)\);'),
    ('modules/video_output/apple/VLCSampleBufferDisplay.m', '0056 render preflight flushes a stalled queue',
     r'if \(!\[sys acceptsPictureLocked:renderer hostTime:hostTime\]\)\s*return -EAGAIN;'),
    ('src/input/resource.c', '0057 a free vout of another drawable is recreated',
     r'p_resource->vout_rsc_free->drawable !=\s*var_InheritAddress\(p_resource->p_parent, "drawable-nsobject"\) \)\s*'
     r'\{\s*msg_Dbg\([^;]*\);\s*DestroyVout\(p_resource\);'),
    ('modules/codec/videotoolbox/decoder.c', '0058 avcC without parameter sets is not trusted',
     r'if \(h264ctx->b_extra_has_config && h264ctx->hh\.i_input_nal_length_size\)'),
    ('modules/codec/videotoolbox/decoder.c', '0058 hvcC without parameter sets is not trusted',
     r'if \(hevcctx->b_extra_has_config && hevcctx->hh\.i_input_nal_length_size\)'),
    ('modules/demux/subtitle.c', '0059 SRT arrows accept surrounding tabs',
     r'const char \*delimiter = strstr\(s, "-->"\);'),
    ('src/video_output/vout_subpictures.c', '0060 SPU cache keys on original parameters',
     r'pos->key\.original_width == subpic->i_original_picture_width &&'),
    ('modules/demux/mp4/mp4.c', '0061 finished MP4 tracks can be deselected',
     r'bool b = true;\s*if\( !tk->b_ok \|\| MP4_isMetadata\( tk \) \)\s*\{\s*continue;'),
    ('modules/demux/adaptive/PlaylistManager.cpp', '0063 a discontinuity drains before its PCR reset',
     r'demux\.discontinuity_draining =\s*es_out_Control\(p_demux->out, ES_OUT_DRAIN\) == VLC_SUCCESS;\s*'
     r'if\(!demux\.discontinuity_draining\)\s*es_out_Control\(p_demux->out, ES_OUT_RESET_PCR\);'),
    ('modules/demux/adaptive/PlaylistManager.cpp', '0063 the deferred PCR reset waits for an empty output',
     r'es_out_Control\(p_demux->out, ES_OUT_IS_EMPTY, &b_empty\);\s*if\(!b_empty\)\s*\{[^}]*\}\s*'
     r'demux\.discontinuity_draining = false;\s*es_out_Control\(p_demux->out, ES_OUT_RESET_PCR\);'),
    ('modules/demux/adaptive/Streams.cpp',
     '0063 a new sequence gets its own synchronization reference; 0070 only on self-anchoring streams',
     r'fakeEsOut\(\)->setSegmentStartTimes\(currentTimeContext\);\s*if\(contiguous\)\s*'
     r'fakeEsOut\(\)->setSynchronizationReference\(\s*SynchronizationReference\(currentSequence, Times\(\)\)\);'),
    ('modules/audio_output/apple/coreaudio_common.c', '0064 timing is reported every 100 ms',
     r'#define TIMING_REPORT_DELAY_TICKS VLC_TICK_FROM_MS\(100\)'),
    ('src/audio_output/dec.c', '0062 stream delay uses the output position at rate != 1',
     r'clock_audio_ts = rate_audio_ts \+ \(system_ts - rate_system_ts\)\s*\* stream->timing\.rate;'),
    ('src/player/player.c', '0065 a recorded failure is an error only once it is terminal',
     r'return input && input->error_reported \? input->error\s*: VLC_PLAYER_ERROR_NONE;'),
    ('src/player/input.c', '0065 only an input that presented nothing fails at its end',
     r'if \(!input->error_reported\s*&& !atomic_load_explicit\(&input->presented,\s*memory_order_relaxed\)\)'),
    ('src/player/input.c', '0065 an input that exposed no stream fails as a demux failure',
     r'if \(error == VLC_PLAYER_ERROR_NONE && !input->has_content\)\s*error = VLC_PLAYER_ERROR_DEMUX;'),
    ('src/player/input.c', '0065 the stopping reason follows the reported error',
     r'input->stopping_reason = input->error_reported\s*\? VLC_PLAYER_MEDIA_STOPPING_ERROR\s*'
     r': VLC_PLAYER_MEDIA_STOPPING_EOS;'),
    ('src/player/player.c', '0066 a paused time read reports the pending seek target',
     r'vlc_player_input_GetTime\(\s*input, input->state == VLC_PLAYER_STATE_PAUSED, vlc_tick_now\(\)\);'),
    ('src/video_output/video_output.c', '0066 only the first paused render after a flush is a forced point',
     r'\|\| \(sys->pause\.is_on && sys->paused_point_pending\)\)\s*system_now = VLC_TICK_MAX;'),
    ('src/clock/clock.c', '0066 a forced-point marker is never used as a date',
     r'else if \(unlikely\(now == VLC_TICK_MAX\)\)\s*now = vlc_tick_now\(\);'),
    ('modules/video_output/vmem.c', '0067 the extended output accepts the nearest pixel',
     r'return 2 \* width_error <= \(source_num > source_den \? source_num : source_den\);'),
    ('modules/video_output/vmem.c', '0067 aspect and crop changes never ask for a picture reset',
     r'case VOUT_DISPLAY_CHANGE_SOURCE_ASPECT:\s*case VOUT_DISPLAY_CHANGE_SOURCE_CROP:\s*'
     r'case VOUT_DISPLAY_CHANGE_SOURCE_PLACE:\s*return VLC_SUCCESS;'),
    ('src/input/input.c', '0068 a frame demand is honoured only while paused',
     r'priv->next_frame_need_data = param\.val\.b_bool\s*&& priv->i_state == PAUSE_S;'),
    ('src/video_output/video_output.c', '0069 a display restart keeps the rate',
     r'sys->rate = restarting \? restart_rate : 1\.f;'),
    ('src/video_output/video_output.c', '0069 a display restart keeps the pause',
     r'if \(restarting && restart_paused\)\s*\{\s*sys->pause\.is_on = true;'),
    ('modules/video_output/apple/VLCSampleBufferDisplay.m', '0071 each prepare drains an autorelease pool',
     r'const vlc_render_subpicture \*subpicture, vlc_tick_t date\)\s*\{\s*@autoreleasepool \{\s*PrepareDisplay\(vd\);'),
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
    print(f'PASS playback reliability source contract ({len(CHECKS)} guards and mutations)')


if __name__ == '__main__':
    main()
