#!/usr/bin/env python3
"""Check the playback-reliability patches 0055-0064 in a patched VLC tree.

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
    ('modules/demux/adaptive/Streams.cpp', '0063 a new sequence gets its own synchronization reference',
     r'fakeEsOut\(\)->setSegmentStartTimes\(currentTimeContext\);\s*fakeEsOut\(\)->setSynchronizationReference\(\s*'
     r'SynchronizationReference\(currentSequence, Times\(\)\)\);'),
    ('modules/audio_output/apple/coreaudio_common.c', '0064 play waits while the rendered queue is long',
     r'p_sys->started && !p_sys->b_paused && p_sys->i_out_size > max_queued\s*'
     r'&& waited < CA_MAX_QUEUE_WAIT_TICKS;'),
    ('modules/audio_output/apple/coreaudio_common.c', '0064 auhal plays through the bounded queue',
     r'p_aout->play = ca_PlayQueued;'),
    ('modules/audio_output/apple/audiounit_ios.m', '0064 iOS waits for the queue outside its lifecycle lock',
     r'ca_WaitOutputQueue\(p_aout\);[^\n]*\n\s*vlc_mutex_lock\(&p_sys->lifecycle_lock\);'),
    ('modules/audio_output/apple/coreaudio_common.c', '0064 timing is reported every 100 ms',
     r'#define TIMING_REPORT_DELAY_TICKS VLC_TICK_FROM_MS\(100\)'),
    ('src/audio_output/dec.c', '0062 stream delay uses the output position at rate != 1',
     r'clock_audio_ts = rate_audio_ts \+ \(system_ts - rate_system_ts\)\s*\* stream->timing\.rate;'),
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
