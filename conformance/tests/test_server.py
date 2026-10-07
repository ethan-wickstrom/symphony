import socket
from http.server import BaseHTTPRequestHandler
import unittest
from unittest.mock import patch

from symphony_conformance.driver.server import Server

ADMISSION_TIMEOUT = 1


class ServerTest(unittest.TestCase):
    def test_timer_start_failure(self):
        failures = []
        primary = RuntimeError("deadline thread admission failed")
        server = Server(("127.0.0.1", 0), BaseHTTPRequestHandler, ADMISSION_TIMEOUT,
                        lambda stage, error: failures.append((stage, error)))
        client = None
        try:
            client = socket.create_connection(server.server_address, timeout=ADMISSION_TIMEOUT)
            with patch("symphony_conformance.driver.server.threading.Timer.start", side_effect=primary):
                with self.assertRaises(RuntimeError) as raised:
                    server.get_request()
            self.assertIs(raised.exception, primary)
            self.assertEqual(failures, [("HTTP admission", primary)])
            self.assertIsNone(server._active)
        finally:
            if client is not None:
                client.close()
            # serve_forever never started; shutdown would wait for that thread.
            server.server_close()


if __name__ == "__main__":
    unittest.main()
