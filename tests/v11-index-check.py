"""Compare the live GC index with an independently reconstructed heap."""
import struct
import subprocess
import sys
from pathlib import Path


def validate(data):
    def require(ok, message):
        if not ok:
            raise ValueError(message)
    def word(buffer, offset):
        require(0 <= offset <= len(buffer) - 8, "truncated word")
        return struct.unpack_from("<Q", buffer, offset)[0]
    address, size = word(data, 0), word(data, 8)
    require(32 <= size <= 64 * 1024 * 1024 and len(data) >= 16 + size + 240, "workspace length")
    workspace = data[16:16 + size]
    context = data[16 + size:16 + size + 240]
    require(word(workspace, 0) == size and word(workspace, 16) == 0, "workspace header")
    mapped = word(context, 72)
    capacity, count = word(workspace, 8), word(workspace, 24)
    require(capacity == mapped // 32 * 8 and count <= 64, "queue bound")
    require(workspace[32:32 + capacity] == bytes(capacity), "fresh queue")
    cursor, arena, total = 16 + size + 240, word(context, 8), 0
    expected_bitmap_at = 32 + capacity + count * 24
    for index in range(count):
        row = 32 + capacity + index * 24
        actual_arena, length, bitmap = (word(workspace, row + n) for n in (0, 8, 16))
        require(actual_arena == arena and arena != 0, "arena row")
        require(length == word(data, cursor + 8) and length >= 4096, "arena length")
        require(cursor + length <= len(data), "arena data")
        require(bitmap - address == expected_bitmap_at, "bitmap placement")
        expected = bytearray(length // 8)
        at = 32
        while at < length:
            physical, flags = word(data, cursor + at), word(data, cursor + at + 8)
            require(physical >= 32 and physical % 8 == 0 and at + physical <= length, "partition")
            if flags:
                expected[at // 8] = 1
            at += physical
        require(at == length, "partition end")
        require(workspace[expected_bitmap_at:expected_bitmap_at + len(expected)] == expected,
                "index differs from allocated physical starts")
        expected_bitmap_at += len(expected)
        arena = word(data, cursor)
        cursor += length
        total += length
    require(arena == 0 and total == mapped and cursor == len(data), "heap boundary")
    require(expected_bitmap_at <= size, "index extent")
    require(workspace[expected_bitmap_at:] == bytes(size - expected_bitmap_at), "map padding")


def main():
    image, expectation = sys.argv[1:]
    result = subprocess.run([image], capture_output=True, timeout=15)
    assert result.returncode == 0 and result.stdout == b"true\n", (result.returncode, result.stdout)
    Path(image).with_suffix(".index").write_bytes(result.stderr)
    try:
        validate(result.stderr)
    except ValueError:
        assert expectation == "reject", "valid index rejected"
    else:
        assert expectation == "accept", "index mutation escaped"
    print("INDEX_CHECK_OK", expectation)


if __name__ == "__main__":
    main()
