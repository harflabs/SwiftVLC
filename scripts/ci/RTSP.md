# RTSP regression coverage

The native engine restores live555 with the unmodified first two contrib patches
from VideoLAN VLCKit tag `4.0.0a18`. Their original author and commit metadata are
retained in patches 0047 and 0048. The resulting dependency is live555
`2016.10.21`, with the SHA-512 pinned by VideoLAN, rather than enabling GNUV3
contribs globally. Reference:
https://code.videolan.org/videolan/VLCKit/-/tree/4.0.0a18/libvlc/patches

`check-rtsp.py` compiles the public libVLC probe against the supplied archive and
uses MediaMTX with an FFmpeg H.264 publisher on loopback. It checks three TCP
sessions, three UDP sessions, authenticated playback, and rejection of an
incorrect password. Successful cases require decoded video frames and completed
stop before release. Each probe has a process timeout and all fixture processes
are terminated on success or failure. CI pins the server archive checksum.

Run with a MediaMTX v1.21.0 executable and FFmpeg available:

```sh
python3 -B scripts/ci/check-rtsp.py \
  --archive Vendor/libvlc.xcframework/macos-arm64_x86_64/libvlc.a \
  --server /absolute/path/to/mediamtx \
  --output .build/ci-results/rtsp
```

These checks do not establish camera interoperability, IPv6, RTSPS/TLS,
multicast, long-running network recovery, or physical iOS behavior. They also do
not make the old dependency equivalent to current live555; any broader support
claim needs its own evidence. The native patch must be included in a newly
released XCFramework before consumers of the declared beta.11 artifact gain
RTSP support.
