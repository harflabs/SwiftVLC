"""Verify MediaMTX's negotiated reader transport for one probe's log window."""
import re


def require_transport(log, path, expected):
    transports = re.findall(
        r"\[RTSP\] \[session [^\]]+\] is reading from path '"
        + re.escape(path) + r"', with ([A-Z]+),", log)
    if transports != [expected]:
        raise RuntimeError(f'{path}: negotiated {transports}, expected one {expected} reader')
