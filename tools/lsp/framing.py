"""Bounded JSON-RPC framing. The idle connection has no deadline."""
import json
import time

MAX_HEADER = 16 * 1024
MAX_BODY = 32 * 1024 * 1024

class ParseError:
    pass

class FrameError(Exception):
    pass

def unique_object(pairs):
    result = {}
    for key, value in pairs:
        if key in result:
            raise ValueError("duplicate JSON member")
        result[key] = value
    return result

class Framer:
    def __init__(self):
        self.buffer = bytearray()
        self.length = None
        self.progress = None

    def feed(self, data):
        self.buffer.extend(data)
        self.progress = time.monotonic()
        messages = []
        while True:
            if self.length is None:
                end = self.buffer.find(b"\r\n\r\n")
                if end < 0:
                    if len(self.buffer) > MAX_HEADER:
                        raise FrameError("header limit exceeded")
                    break
                if end + 4 > MAX_HEADER:
                    raise FrameError("header limit exceeded")
                fields = {}
                for line in bytes(self.buffer[:end]).split(b"\r\n"):
                    name, sep, value = line.partition(b":")
                    if not sep:
                        raise FrameError("invalid header")
                    try:
                        key = name.decode("ascii").lower()
                        value = value.decode("ascii").strip()
                    except UnicodeError as error:
                        raise FrameError("invalid header encoding") from error
                    if key in fields:
                        raise FrameError("duplicate header")
                    fields[key] = value
                length = fields.get("content-length", "")
                if not length.isascii() or not length.isdecimal() or len(length) > 10:
                    raise FrameError("invalid Content-Length")
                self.length = int(length)
                if not 0 < self.length <= MAX_BODY:
                    raise FrameError("body limit exceeded")
                del self.buffer[:end + 4]
                self.progress = time.monotonic()
            if len(self.buffer) < self.length:
                break
            body = bytes(self.buffer[:self.length])
            del self.buffer[:self.length]
            self.length = None
            try:
                messages.append(json.loads(body.decode("utf-8"), object_pairs_hook=unique_object,
                                           parse_constant=lambda _: (_ for _ in ()).throw(ValueError())))
            except (ValueError, UnicodeError, RecursionError) as error:
                messages.append(ParseError())
            self.progress = time.monotonic() if self.buffer else None
        return messages

    def check_deadline(self):
        if self.progress is not None:
            budget = 10 if self.length is not None else 5
            if time.monotonic() - self.progress >= budget:
                raise FrameError("partial frame made no progress")

    def eof(self):
        if self.buffer or self.length is not None:
            raise FrameError("truncated frame")

def encode(message):
    body = json.dumps(message, ensure_ascii=True, separators=(",", ":"), allow_nan=False).encode()
    return b"Content-Length: " + str(len(body)).encode() + b"\r\n\r\n" + body
