#!/usr/bin/env python3
"""Compile failure-recovery logic from integrated VLC and check its call sites."""
import argparse
import os
from pathlib import Path
import re
import subprocess
import tempfile


def block(text, marker):
    start = text.index(marker)
    opening = text.index('{', start)
    depth = 1
    end = opening + 1
    while depth:
        depth += (text[end] == '{') - (text[end] == '}')
        end += 1
    return text[start:end]


def require(condition, message):
    if not condition:
        raise RuntimeError(message)


def check_calls(root):
    playlist = (root / 'lib/media_list_player.c').read_text()
    mode = block(playlist, 'void libvlc_media_list_player_set_playback_mode(')
    require('lock_internal(p_mlp);' in mode and not re.search(r'\block\(p_mlp\)', mode),
            'mode changes must preserve transport generation under both locks')
    worker = block(playlist, 'static void *playlist_thread(')
    require('operation_generation == mlp->operation_generation' in worker,
            'explicit transport must still invalidate an obsolete handoff')
    source = (root / 'src/player/input.c').read_text()
    failure = source.split('case INPUT_EVENT_FAILURE:', 1)[1].split('break;', 1)[0]
    recovery = source.split('case INPUT_EVENT_RECOVERY:', 1)[1].split('break;', 1)[0]
    for body, operation in [(failure, 'RecordFailure'), (recovery, 'RecoverFailure')]:
        require('if (!input->error_reported)' in body, 'terminal attribution must remain final')
        require(f'vlc_player_input_{operation}(&input->failures, event->failure)' in body,
                f'missing input {operation} integration')
        require('input->error = vlc_player_input_CurrentFailure(&input->failures)' in body,
                'input attribution must follow unresolved failures')
    require('input->failures = (struct vlc_player_input_failures) {0};' in source,
            'each input must start with an empty failure tracker')
    decoder = (root / 'src/input/decoder.c').read_text()
    require(decoder.count('p_owner->reported_failures = 0;') == 1,
            'only decoder construction can silently clear reported failures')
    require('Decoder_ReportFailure(p_owner, VLC_INPUT_FAILURE_RENDERER);' in decoder,
            'renderer failures must be counted')
    require('Decoder_ReportFailure(p_owner, VLC_INPUT_FAILURE_OUTPUT);' in decoder,
            'audio failures must be counted')
    require(re.search(r'p_owner->video.started = true;\s*Decoder_ReportRecovery\(p_owner, VLC_INPUT_FAILURE_RENDERER\);', decoder),
            'renderer recovery must follow successful vout creation')
    require(re.search(r'case VLCDEC_SUCCESS:\s*Decoder_ReportRecovery\(p_owner, VLC_INPUT_FAILURE_DECODER\);', decoder),
            'decoder recovery must follow successful decoding')
    require(re.search(r'case VLCDEC_ECRITICAL:\s*Decoder_ReportFailure\(p_owner, VLC_INPUT_FAILURE_DECODER\);', decoder),
            'critical decoder failure must remain attributed')
    require(re.search(r'if\( p_aout == NULL \)\s*\{\s*Decoder_ReportFailure\(p_owner, VLC_INPUT_FAILURE_OUTPUT\);\s*vlc_fifo_Unlock\(p_owner->p_fifo\);\s*return -1;\s*\}\s*Decoder_ReportRecovery\(p_owner, VLC_INPUT_FAILURE_OUTPUT\);', decoder),
            'audio recovery must follow successful output creation')
    es = (root / 'src/input/es_out.c').read_text()
    require('.on_recovery = decoder_on_recovery,' in es and
            'input_SendEventRecovery(sys->p_input, kind);' in es,
            'decoder recovery must reach the input event bridge')
    event = block((root / 'src/input/event.h').read_text(), 'static inline void input_SendEventRecovery(')
    require('.type = INPUT_EVENT_RECOVERY' in event and '.failure = kind' in event,
            'recovery events must preserve their subsystem')
    return decoder


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('source', type=Path)
    args = parser.parse_args()
    root = args.source
    decoder = check_calls(root)
    kinds = block((root / 'src/input/input_internal.h').read_text(), 'enum vlc_input_failure_kind') + ';'
    errors = block((root / 'include/vlc_player.h').read_text(), 'enum vlc_player_error\n') + ';'
    header = (root / 'src/player/input_failure.h').read_text()
    helpers = '\n'.join(block(decoder, 'static void ' + name + '(')
                        for name in ['Decoder_ReportFailure', 'Decoder_ReportRecovery'])
    harness = r'''
#include <stdbool.h>
#include <stdio.h>
#include <stdlib.h>
#define CHECK(value) do { if (!(value)) { fprintf(stderr, "line %d: %s\n", __LINE__, #value); return 1; } } while (0)
static struct vlc_player_input_failures tracker;
static unsigned notifications;
typedef struct { unsigned reported_failures; } vlc_input_decoder_t;
static void on_failure(enum vlc_input_failure_kind kind) {
    notifications++; vlc_player_input_RecordFailure(&tracker, kind);
}
static void on_recovery(enum vlc_input_failure_kind kind) {
    notifications++; vlc_player_input_RecoverFailure(&tracker, kind);
}
#define decoder_Notify(owner, event, kind) event(kind)
'''
    tests = r'''
int main(void) {
    vlc_input_decoder_t first = {0}, second = {0};
    Decoder_ReportFailure(&first, VLC_INPUT_FAILURE_RENDERER);
    Decoder_ReportFailure(&first, VLC_INPUT_FAILURE_RENDERER);
    CHECK(notifications == 1);
    CHECK(vlc_player_input_CurrentFailure(&tracker) == VLC_PLAYER_ERROR_RENDERER);
    Decoder_ReportFailure(&second, VLC_INPUT_FAILURE_RENDERER);
    Decoder_ReportRecovery(&first, VLC_INPUT_FAILURE_RENDERER);
    Decoder_ReportRecovery(&first, VLC_INPUT_FAILURE_RENDERER);
    CHECK(notifications == 3);
    CHECK(vlc_player_input_CurrentFailure(&tracker) == VLC_PLAYER_ERROR_RENDERER);
    Decoder_ReportRecovery(&second, VLC_INPUT_FAILURE_RENDERER);
    CHECK(vlc_player_input_CurrentFailure(&tracker) == VLC_PLAYER_ERROR_NONE);
    Decoder_ReportFailure(&first, VLC_INPUT_FAILURE_OUTPUT);
    Decoder_ReportFailure(&first, VLC_INPUT_FAILURE_DECODER);
    Decoder_ReportRecovery(&first, VLC_INPUT_FAILURE_OUTPUT);
    CHECK(vlc_player_input_CurrentFailure(&tracker) == VLC_PLAYER_ERROR_DECODER);
    Decoder_ReportRecovery(&first, VLC_INPUT_FAILURE_DECODER);
    CHECK(vlc_player_input_CurrentFailure(&tracker) == VLC_PLAYER_ERROR_NONE);
    Decoder_ReportFailure(&first, VLC_INPUT_FAILURE_RENDERER);
    vlc_player_input_RecordFailure(&tracker, VLC_INPUT_FAILURE_DEMUX);
    Decoder_ReportRecovery(&first, VLC_INPUT_FAILURE_RENDERER);
    CHECK(vlc_player_input_CurrentFailure(&tracker) == VLC_PLAYER_ERROR_DEMUX);
    vlc_player_input_RecoverFailure(&tracker, VLC_INPUT_FAILURE_DEMUX);
    CHECK(vlc_player_input_CurrentFailure(&tracker) == VLC_PLAYER_ERROR_DEMUX);
    puts("PASS retry de-duplication, independent decoders, recovery, and unrecovered attribution");
    return 0;
}
'''
    with tempfile.TemporaryDirectory(prefix='swiftvlc-failure-source-') as temp:
        source = Path(temp) / 'probe.c'
        executable = Path(temp) / 'probe'
        def run(candidate_header, candidate_helpers, expected):
            source.write_text(kinds + '\n' + errors + '\n' + candidate_header + harness + candidate_helpers + tests)
            subprocess.run([os.environ.get('CC', 'cc'), '-std=c11', '-Wall', '-Wextra', '-Werror',
                            str(source), '-o', str(executable)], check=True, capture_output=True)
            result = subprocess.run([str(executable)], capture_output=True, text=True, timeout=10)
            require((result.returncode == 0) == expected, result.stdout + result.stderr)
        run(header, helpers, True)
        for old, new in [('--state->counts[kind] != 0', '--state->counts[kind] == UINT_MAX'),
                         ('state->length--;', '/* lost removal */'),
                         ('if (state->length == 0) return VLC_PLAYER_ERROR_NONE;',
                          'if (state->length == 0) return VLC_PLAYER_ERROR_RENDERER;')]:
            require(old in header, 'mutation target missing')
            run(header.replace(old, new), helpers, False)
        run(header, helpers.replace('owner->reported_failures |= 1u << kind;', '/* lost de-duplication */'), False)
    print('PASS native playback source integration and compiled recovery logic (4 rejected mutations)')


if __name__ == '__main__':
    main()
