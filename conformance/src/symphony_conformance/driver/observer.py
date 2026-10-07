"""Fixture subprocesses publish observations without deciding verdicts."""

import json
import urllib.request
from http import HTTPStatus

POST_TIMEOUT = 5


class Observer:
    def __init__(self, url, origin):
        self._url = url
        self._origin = origin
        self._opener = urllib.request.build_opener(urllib.request.ProxyHandler({}))

    def emit(self, kind, data):
        raw = json.dumps({"origin": self._origin, "kind": kind, "data": data},
                         separators=(",", ":"), allow_nan=False).encode()
        request = urllib.request.Request(self._url, data=raw, method="POST",
                                         headers={"Content-Type": "application/json"})
        with self._opener.open(request, timeout=POST_TIMEOUT) as response:
            if response.status != HTTPStatus.NO_CONTENT:
                raise ValueError("Evidence collector rejected fixture event")
