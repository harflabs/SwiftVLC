#!/usr/bin/env python3
"""Exercise the built libVLC against a loopback MediaMTX RTSP fixture.

Requires ffmpeg and a MediaMTX binary supplied by the caller. No camera,
credentials, LAN listener, or external stream is used.
"""
import argparse
import pathlib
import socket
import subprocess
import tempfile
import time
from rtsp_transport import require_transport

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('--archive', type=pathlib.Path, required=True)
parser.add_argument('--server', type=pathlib.Path, required=True)
parser.add_argument('--output', type=pathlib.Path, required=True)
args = parser.parse_args()
args.output.mkdir(parents=True, exist_ok=True)
root = pathlib.Path(__file__).resolve().parents[2]

def port(kind=socket.SOCK_STREAM):
    with socket.socket(socket.AF_INET, kind) as sock:
        sock.bind(('127.0.0.1', 0))
        return sock.getsockname()[1]

with tempfile.TemporaryDirectory(prefix='swiftvlc-rtsp-') as temporary:
    tmp = pathlib.Path(temporary)
    executable = tmp / 'probe'
    compile_args = ['clang', '-I', str(args.archive.parent / 'Headers'),
                    str(root / 'scripts/ci/rtsp-playback-probe.c'), str(args.archive), '-o', str(executable)]
    for framework in ('AppKit AudioToolbox AudioUnit AVFoundation AVKit CoreAudio CoreFoundation '
                      'CoreGraphics CoreImage CoreMedia CoreServices CoreText CoreVideo Foundation '
                      'IOKit IOSurface OpenGL QuartzCore Security SystemConfiguration VideoToolbox').split():
        compile_args += ['-framework', framework]
    compile_args += '-lbz2 -lc++ -liconv -lresolv -lsqlite3 -lxml2 -lz'.split()
    subprocess.run(compile_args, check=True, timeout=120)
    rtsp = port()
    while True:
        rtp = port(socket.SOCK_DGRAM)
        if rtp % 2: continue
        rtcp = rtp + 1
        try:
            with socket.socket(socket.AF_INET, socket.SOCK_DGRAM) as sock:
                sock.bind(("127.0.0.1", rtcp))
            break
        except OSError: continue
    config = tmp / 'server.yml'
    config.write_text(f'''logLevel: debug
rtspAddress: 127.0.0.1:{rtsp}
rtspTransports: [udp, tcp]
rtpAddress: 127.0.0.1:{rtp}
rtcpAddress: 127.0.0.1:{rtcp}
rtmp: false
hls: false
webrtc: false
srt: false
moq: false
authInternalUsers:
  - user: any
    ips: [127.0.0.1]
    permissions:
      - action: publish
        path: test
      - action: read
        path: test
  - user: fixture
    pass: fixture-password
    ips: [127.0.0.1]
    permissions:
      - action: read
        path: protected
paths:
  test:
  protected:
    source: rtsp://127.0.0.1:{rtsp}/test
    sourceOnDemand: true
''')
    processes = []
    logs = []
    try:
        for name, command in [('server', [str(args.server.resolve()), str(config)])]:
            log = (args.output / (name+'.log')).open('w'); logs.append(log)
            processes.append(subprocess.Popen(command, stdout=log, stderr=subprocess.STDOUT))
        deadline = time.monotonic()+10
        while True:
            if processes[0].poll() is not None:
                raise RuntimeError('RTSP server exited; inspect server.log')
            try:
                with socket.create_connection(('127.0.0.1',rtsp),timeout=0.2): break
            except OSError:
                if time.monotonic() > deadline: raise RuntimeError('RTSP server startup timed out')
                time.sleep(0.1)
        log = (args.output / 'publisher.log').open('w'); logs.append(log)
        processes.append(subprocess.Popen(['ffmpeg','-hide_banner','-loglevel','error','-re',
            '-stream_loop','-1','-i',str(root/'Tests/SwiftVLCTests/Fixtures/twosec.mp4'),
            '-an','-c:v','libx264','-preset','ultrafast','-tune','zerolatency',
            # Late readers need a fresh IDR without waiting for x264's default
            # 250-frame GOP (10 seconds for this 25 fps fixture).
            '-g','25','-keyint_min','25','-sc_threshold','0',
            '-f','rtsp','-rtsp_transport','tcp',f'rtsp://127.0.0.1:{rtsp}/test'],stdout=log,stderr=subprocess.STDOUT))
        deadline=time.monotonic()+10
        while 'is publishing to path' not in (args.output/'server.log').read_text():
            if processes[-1].poll() is not None or time.monotonic()>deadline:
                raise RuntimeError('RTSP publisher did not become ready')
            time.sleep(0.1)
        cases = [(f'{mode}-{i}',f'rtsp://127.0.0.1:{rtsp}/test',option,0)
                 for mode,option in [('tcp',':rtsp-tcp'),('udp',':no-rtsp-tcp')] for i in range(3)]
        cases += [('authenticated',f'rtsp://fixture:fixture-password@127.0.0.1:{rtsp}/protected',':rtsp-tcp',0),
                  ('bad-password',f'rtsp://fixture:wrong@127.0.0.1:{rtsp}/protected',':rtsp-tcp',1)]
        for name,url,option,expected in cases:
            # Restrict evidence to this case; a prior successful UDP session
            # must not mask fallback to TCP in a later case.
            server_log = args.output / 'server.log'
            log_offset = server_log.stat().st_size
            result=subprocess.run([str(executable),url,option],stdout=subprocess.PIPE,stderr=subprocess.STDOUT,timeout=35)
            (args.output/(name+'.log')).write_bytes(result.stdout)
            if result.returncode != expected:
                print(result.stdout.decode('utf-8', errors='replace')[-6000:], flush=True)
                raise RuntimeError(f'{name}: exit {result.returncode}, expected {expected}')
            if expected == 0:
                with server_log.open('rb') as evidence:
                    evidence.seek(log_offset)
                    case_log = evidence.read().decode('utf-8')
                require_transport(case_log, 'protected' if name == 'authenticated' else 'test',
                                  'UDP' if name.startswith('udp-') else 'TCP')
            print(f'PASS {name}',flush=True)
    finally:
        for process in reversed(processes):
            if process.poll() is None:
                process.terminate()
                try: process.wait(timeout=5)
                except subprocess.TimeoutExpired:
                    process.kill(); process.wait(timeout=5)
        for log in logs: log.close()
