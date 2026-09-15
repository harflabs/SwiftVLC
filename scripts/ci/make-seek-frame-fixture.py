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

# Verify actual decoded pixel values, independently of VLC's timestamps.
indices = [0, 30, 359, 360, 705, 1000, 1799]
selection = '+'.join(f'eq(n\\,{n})' for n in indices)
data = subprocess.check_output([
    'ffmpeg', '-hide_banner', '-loglevel', 'error', '-nostdin', '-i', str(mp4),
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
print('MP4_SHA256=' + hashlib.sha256(mp4.read_bytes()).hexdigest())
