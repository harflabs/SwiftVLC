import importlib.util
import unittest
from pathlib import Path

SPEC = importlib.util.spec_from_file_location(
    'rtsp_transport', Path(__file__).resolve().parents[1] / 'rtsp_transport.py')
TRANSPORT = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(TRANSPORT)


def reader(transport, path='test'):
    return f"INF [RTSP] [session abc123] is reading from path '{path}', with {transport}, 1 track (H264)\n"


class RTSPTransportTests(unittest.TestCase):
    def test_requested_transport_is_required(self):
        for transport in ('UDP', 'TCP'):
            TRANSPORT.require_transport(reader(transport), 'test', transport)

    def test_fallback_missing_and_multiple_readers_fail(self):
        for log in ('', reader('TCP'), reader('UDP') + reader('TCP'), reader('UDP') * 2):
            with self.subTest(log=log), self.assertRaises(RuntimeError):
                TRANSPORT.require_transport(log, 'test', 'UDP')

    def test_relay_transport_does_not_mask_client_transport(self):
        log = reader('UDP') + reader('TCP', 'protected')
        TRANSPORT.require_transport(log, 'protected', 'TCP')
        with self.assertRaises(RuntimeError):
            TRANSPORT.require_transport(log, 'protected', 'UDP')
