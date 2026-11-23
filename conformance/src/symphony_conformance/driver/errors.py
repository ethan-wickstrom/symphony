"""Bound diagnostic samples while retaining the number omitted."""

MAX_ERROR_SAMPLES = 16
MAX_ERROR_CHARS = 512


class Failures:
    def __init__(self):
        self._samples = []
        self._omitted = 0

    def record(self, message):
        if len(self._samples) >= MAX_ERROR_SAMPLES:
            self._omitted += 1
            return
        self._samples.append(message[:MAX_ERROR_CHARS])

    def samples(self):
        result = list(self._samples)
        if self._omitted:
            result.append("Further errors omitted: " + str(self._omitted))
        return result
