"""Generate a frame-number oracle and remux the same content as HLS VOD.

Usage: python3 make-frame-fixture.py /absolute/path/to/fixtures [--verify-only]
Requires ffmpeg on PATH. No remote media is used.
"""
from pathlib import Path
import subprocess, sys, hashlib

root = Path(sys.argv[1]).resolve()
root.mkdir(parents=True, exist_ok=True)
mp4 = root / 'frame-index.mp4'
hls = root / 'hls'
hls.mkdir(exist_ok=True)
if '--verify-only' not in sys.argv:
    subprocess.run([
        'ffmpeg', '-hide_banner', '-loglevel', 'error', '-nostdin',
        '-f', 'lavfi', '-i',
        "nullsrc=s=320x180:r=30,geq=lum='if(lt(Y,64),32+192*mod(floor(N/pow(2,floor(X/20))),2),mod(X*3+Y*5+N*7,220)+16)':cb=128:cr=128",
        '-f', 'lavfi', '-i', 'sine=frequency=700:sample_rate=48000',
        '-t', '60', '-c:v', 'libx264', '-preset', 'fast', '-crf', '18',
        '-g', '250', '-keyint_min', '250', '-sc_threshold', '0', '-bf', '3',
        '-c:a', 'aac', '-b:a', '96k', '-movflags', '+faststart', '-y', str(mp4)
    ], check=True)
    subprocess.run([
        'ffmpeg', '-hide_banner', '-loglevel', 'error', '-nostdin', '-i', str(mp4),
        '-c', 'copy', '-hls_time', '4', '-hls_list_size', '0',
        '-hls_playlist_type', 'vod', '-y', str(hls / 'index.m3u8')
    ], check=True)

# A subtitle every second is intentional: one cue spanning the whole seek
# might never be submitted after demux preroll and would miss paused input demand.
subtitles = root / 'seek-caption.srt'
subtitled = root / 'frame-subtitle.mkv'
if '--verify-only' not in sys.argv:
    subtitles.write_text(''.join(
        f'{i + 1}\n00:00:{i:02},000 --> 00:00:{i:02},900\nSubtitle {i}\n\n'
        for i in range(60)
    ))
    subprocess.run([
        'ffmpeg', '-hide_banner', '-loglevel', 'error', '-nostdin',
        '-i', str(mp4), '-i', str(subtitles), '-map', '0', '-map', '1',
        '-c', 'copy', '-disposition:s:0', 'default', '-y', str(subtitled)
    ], check=True)

# Open-GOP H.264 needs both recovery-point decoder reset and rejection of
# leading pictures that still reference the previous GOP. Use moving colored
# content: a barcode alone can survive while the rest of the frame is corrupt.
# Both dimensions are multiples of 16 for the hardware-to-vmem conversion.
open_gop = root / 'open-gop.mp4'
if '--verify-only' not in sys.argv:
    subprocess.run([
        'ffmpeg', '-hide_banner', '-loglevel', 'error', '-nostdin',
        '-f', 'lavfi', '-i',
        "testsrc2=s=320x192:r=30,geq=lum='if(lt(Y,64),32+192*mod(floor(N/pow(2,floor(X/20))),2),lum(X,Y))':cb='if(lt(Y,32),128,cb(X,Y))':cr='if(lt(Y,32),128,cr(X,Y))'",
        '-f', 'lavfi', '-i', 'sine=frequency=700:sample_rate=48000',
        '-t', '12', '-c:v', 'libx264', '-preset', 'fast', '-crf', '18',
        '-x264-params', 'open-gop=1:keyint=60:min-keyint=60:scenecut=0:bframes=3:b-adapt=0',
        '-color_primaries', 'bt709', '-color_trc', 'bt709', '-colorspace', 'bt709',
        '-c:a', 'aac', '-b:a', '96k', '-movflags', '+faststart', '-y', str(open_gop)
    ], check=True)
for target in [7, 3, 9, 2, 6]:
    data = subprocess.check_output([
        'ffmpeg', '-hide_banner', '-loglevel', 'error', '-nostdin', '-i', str(open_gop),
        '-vf', f'select=eq(n\\,{target * 30})', '-frames:v', '1',
        '-pix_fmt', 'argb', '-f', 'rawvideo', '-'
    ])
    assert len(data) == 320 * 192 * 4
    reference = root / f'open-gop-{target}.argb'
    if '--verify-only' in sys.argv:
        assert reference.read_bytes() == data, reference
    else:
        reference.write_bytes(data)
    print(f'FFMPEG_HARDWARE_REFERENCE time={target} sha256={hashlib.sha256(data).hexdigest()}')

# Verify actual decoded pixel values, independently of VLC's timestamps.
indices = [0, 30, 359, 360, 705, 1000, 1799]
selection = '+'.join(f'eq(n\\,{n})' for n in indices)
for source in [mp4, subtitled]:
    data = subprocess.check_output([
        'ffmpeg', '-hide_banner', '-loglevel', 'error', '-nostdin', '-i', str(source),
        '-vf', 'select=' + selection, '-fps_mode', 'passthrough',
        '-pix_fmt', 'gray', '-f', 'rawvideo', '-'
    ])
    frame_size = 320 * 180
    assert len(data) == frame_size * len(indices)
    for slot, expected in enumerate(indices):
        frame = data[slot * frame_size:(slot + 1) * frame_size]
        decoded = sum((1 << bit) for bit in range(16) if frame[32 * 320 + bit * 20 + 10] > 128)
        assert decoded == expected, (decoded, expected)
        print(f'FFMPEG_ORACLE frame={expected} decoded_barcode={decoded}')
    print(source.name + '_SHA256=' + hashlib.sha256(source.read_bytes()).hexdigest())
