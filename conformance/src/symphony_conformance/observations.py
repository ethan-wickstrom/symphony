"""Bound candidate-derived evidence while retaining exact capture bytes."""

import base64

from .assets import decode, encode
from .driver.capture import READ_CHUNK
from .driver.journal import MAX_EVENTS, MAX_EVENT_BYTES, MAX_JOURNAL_BYTES
from .records import check_data

PROFILE_SHARE = 4
MAX_RECORDS = MAX_EVENTS // PROFILE_SHARE
MAX_RECORD_BYTES = MAX_EVENT_BYTES // PROFILE_SHARE
MAX_PROFILE_BYTES = MAX_JOURNAL_BYTES // PROFILE_SHARE
MAX_DIAGNOSTICS = 16
STREAMS = ("stdout", "stderr")


class Observations:
    def __init__(self, journal, stream, origin, parse):
        self._journal = journal
        self._stream = stream
        self._origin = origin
        self._parse = parse
        self._raw = {name: bytearray() for name in STREAMS}
        self._pending = bytearray()
        self._records = 0
        self._bytes = 0
        self._diagnostics = 0
        self._malformed = 0
        self._omitted_invalid = 0
        self._omitted_valid = 0
        self._limited = False

    def __call__(self, kind, data):
        if kind not in {"capture.stdout", "capture.stderr"}:
            self._flush_all()
            return self._journal.emit(kind, data)

        stream = kind.split(".")[1]
        raw = base64.b64decode(data["data_b64"], validate=True)
        self._raw[stream].extend(raw)
        while len(self._raw[stream]) >= READ_CHUNK:
            self._flush(stream, READ_CHUNK)
        if stream == self._stream:
            self._lines(raw)

    def _flush(self, stream, size=None):
        pending = self._raw[stream]
        if not pending:
            return
        size = len(pending) if size is None else size
        raw = bytes(pending[:size])
        self._journal.emit("capture." + stream,
                           {"data_b64": base64.b64encode(raw).decode(), "bytes": len(raw)})
        del pending[:size]

    def _flush_all(self):
        for stream in STREAMS:
            self._flush(stream)

    def _lines(self, raw):
        # Search only newly received bytes; keep an unterminated tail in place.
        start = len(self._pending)
        self._pending.extend(raw)
        consumed = 0
        while True:
            end = self._pending.find(b"\n", start)
            if end < 0:
                break
            self._line(bytes(self._pending[consumed:end]))
            consumed = end + 1
            start = consumed
        if consumed:
            del self._pending[:consumed]

    def _line(self, line):
        try:
            value = self._parse(line)
        except (UnicodeError, ValueError, TypeError) as error:
            self._malformed += 1
            data = {"stream": self._stream, "error_type": type(error).__name__}
            if self._diagnostics < MAX_DIAGNOSTICS and self._admit("candidate.observation_error", data):
                self._diagnostics += 1
                return
            self._omitted_invalid += 1
            self._limit()
            return

        if value is None:
            return
        if not self._admit("candidate.observation", value, self._origin):
            self._omitted_valid += 1
            self._limit()

    def _admit(self, kind, data, origin="executor"):
        # Admission uses the journal encoding and includes its data envelope.
        try:
            check_data(data)
            raw = encode({"data": data})
            decode(raw)
        except (UnicodeError, ValueError, TypeError, RecursionError):
            return False
        if (self._records >= MAX_RECORDS or len(raw) > MAX_RECORD_BYTES
                or len(raw) > MAX_PROFILE_BYTES - self._bytes):
            return False

        self._flush(self._stream)
        # Recorder failures remain infrastructure failures.
        self._journal.emit(kind, data, origin)
        self._records += 1
        self._bytes += len(raw)
        return True

    def _limit(self):
        if self._limited:
            return
        self._flush(self._stream)
        self._journal.emit("candidate.observation_limit", {"stream": self._stream,
                           "max_records": MAX_RECORDS, "max_record_bytes": MAX_RECORD_BYTES,
                           "max_profile_bytes": MAX_PROFILE_BYTES, "max_diagnostics": MAX_DIAGNOSTICS})
        self._limited = True

    def close(self):
        self._flush_all()
        if self._limited:
            self._journal.emit("candidate.observation_summary", {"stream": self._stream,
                               "malformed": self._malformed, "omitted_invalid": self._omitted_invalid,
                               "omitted_valid": self._omitted_valid})
