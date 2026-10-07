import http.client
import socket
import threading
from http import HTTPStatus
from http.server import BaseHTTPRequestHandler
import unittest
from unittest.mock import patch

from symphony_conformance.driver.server import Server

ADMISSION_TIMEOUT = 1


class ServerTest(unittest.TestCase):
    def test_numeric_bind_avoids_dns(self):
        failures = []

        class Handler(BaseHTTPRequestHandler):
            def log_message(self, *_args):
                return

            def do_GET(self):
                self.send_response(HTTPStatus.NO_CONTENT)
                self.send_header("Content-Length", "0")
                self.end_headers()

        server = thread = client = None
        with patch("socket.getfqdn", side_effect=RuntimeError("numeric listener attempted reverse DNS")) as resolver:
            try:
                server = Server(("127.0.0.1", 0), Handler, ADMISSION_TIMEOUT,
                                lambda stage, error: failures.append((stage, error)))
                self.assertEqual(server.server_name, "127.0.0.1")
                self.assertEqual(server.server_port, server.server_address[1])
                self.assertGreater(server.server_port, 0)
                thread = threading.Thread(target=server.serve_forever)
                thread.start()
                client = http.client.HTTPConnection(*server.server_address, timeout=ADMISSION_TIMEOUT)
                client.request("GET", "/")
                response = client.getresponse()
                self.assertEqual(response.status, HTTPStatus.NO_CONTENT)
                self.assertEqual(response.read(), b"")
            finally:
                if client is not None:
                    client.close()
                if server is not None:
                    if thread is not None and thread.ident is not None:
                        server.close()
                        thread.join(ADMISSION_TIMEOUT)
                    else:
                        # A failed constructor/start owns only the listener.
                        server.server_close()
            resolver.assert_not_called()
        self.assertFalse(thread.is_alive())
        self.assertEqual(server.socket.fileno(), -1)
        self.assertEqual(failures, [])

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
