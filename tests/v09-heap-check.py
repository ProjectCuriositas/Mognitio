"""Independent reader for ABI v5 context, arena geometry, and trace metadata."""
import hashlib
import struct
import subprocess
import sys

artifact, mode = sys.argv[1:3]
image = open(artifact, "rb").read()
result = subprocess.run([artifact], capture_output=True, timeout=45)
assert result.returncode == 0, (result.returncode, result.stderr[:200])
assert result.stdout == b"true\n"
record = result.stderr
words = struct.unpack_from("<30Q", record)
root, arena, page, value = words[:4]
allocs, allocated, collections, reclaimed, freed, mapped, reused = words[4:11]
assert root == 0 and value == 1 and page > 0
phoff = struct.unpack_from("<Q", image, 32)[0]
file_start, virtual_start, _, file_size = struct.unpack_from("<4Q", image, phoff + 8)

def static(address, count):
    offset = address - virtual_start + file_start
    assert 0 <= offset <= len(image) - count * 8, (address, count)
    return struct.unpack_from("<" + "Q" * count, image, offset)

def code_pointer(address):
    assert virtual_start + 128 <= address < virtual_start + file_size

cursor = 240
blocks, kinds, arrays = {}, set(), []
while arena:
    nxt, size, first, reserved = struct.unpack_from("<4Q", record, cursor)
    assert first == 32 and reserved == 0 and size % page == 0
    assert cursor + size <= len(record)
    arrays.append(size)
    offset, previous_free = 32, False
    while offset < size:
        physical, flags, metadata, tag = struct.unpack_from("<4Q", record, cursor + offset)
        assert physical >= 32 and physical % 8 == 0 and offset + physical <= size
        assert flags in (0, 1, 17, 33, 49, 65, 81, 97), flags
        assert not (previous_free and flags == 0), "adjacent free blocks not coalesced"
        if flags:
            kind = flags >> 4
            kinds.add(kind)
            payload = record[cursor + offset + 32:cursor + offset + physical]
            children = []
            if kind == 0:
                assert metadata <= len(payload)
                assert len(payload[:metadata].decode("utf-8")) == tag
            else:
                dk, identity, variant, count, refs = static(metadata, 5)
                assert dk == kind and count * 8 <= len(payload)
                slots = struct.unpack_from("<" + "Q" * (len(payload)//8), payload)
                indices = static(metadata + 40, refs)
                assert list(indices) == sorted(set(indices))
                assert all(i < count for i in indices)
                children = [slots[i] for i in indices]
                if kind == 3:
                    impl, contract, methods = static(tag, 3)
                    assert impl == identity and count == 1 and indices in ((), (0,))
                    for address in static(tag + 24, methods):
                        code_pointer(address)
                elif kind == 4:
                    assert tag == 0 and 0 not in indices
                    code_pointer(slots[0])
                elif kind == 5:
                    assert count == 3 and indices in ((1,), (1, 2))
                    assert slots[0] > 0 and slots[1] != 0
                elif kind == 6:
                    assert count == 1 and refs == 0 and slots[0] <= len(slots) - 1
                    ref_element, = static(metadata + 40, 1)
                    assert ref_element in (0, 1)
                    if ref_element:
                        children = list(slots[1:1 + slots[0]])
                else:
                    assert tag == variant
            blocks[arena + offset] = (kind, children, payload)
        previous_free = flags == 0
        offset += physical
    assert offset == size
    cursor += size
    arena = nxt
assert cursor == len(record) and mapped == sum(arrays)
# Every traced edge is an allocated start or a well-formed emitted static object.
for kind, children, payload in blocks.values():
    for child in children:
        if child == 0:
            assert kind in (5, 6), "null reference outside list/buffer"
        elif child not in blocks:
            size, flags, metadata, tag = static(child, 4)
            assert flags & 5 == 5 and not (flags & ~0x75)
            assert size >= 32 and size % 8 == 0
            if flags >> 4:
                dk, = static(metadata, 1)
                assert dk == flags >> 4
if mode == "lifetime":
    assert allocs > 8000 and allocated > 64 * 4096
    assert mapped == 4096 and reclaimed > 0 and freed > 0 and reused == 1
    assert 0 < words[23] < 2048 and 0 < words[24] < 4096
    assert words[12] == 3
    trace = [words[14:17], words[17:20], words[20:23]]
    assert [t[0] for t in trace] == [1, 2, 3]
    assert all(t[1] == words[11] for t in trace)
    assert trace[0][2] == trace[1][2] == words[13]
    assert 0 < trace[2][2] <= words[13]
    assert set(range(7)) <= kinds, kinds
    assert any(kind == 0 and b"keep!" in payload for kind, _, payload in blocks.values())
elif mode == "extracted":
    assert mapped == 4096 and allocs > 6000 and reclaimed > 5900
    texts = {address for address, (kind, _, payload) in blocks.items() if kind == 0 and payload.startswith(b"child!")}
    assert len(texts) == 1
    leaves = {address for address, (kind, children, _) in blocks.items() if kind == 1 and children == list(texts)}
    assert len(leaves) == 1
    assert not any(kind == 1 and leaves.intersection(children) for kind, children, _ in blocks.values()), "dead parent retained"
elif mode in ("reverse", "forward"):
    n = int(sys.argv[3])
    assert allocs == n and collections == 1 and reclaimed == 0
    nodes = [(address, data) for address, data in blocks.items() if data[0] == 5]
    assert len(nodes) == n
    nodes.sort()
    for i, (address, (_, children, payload)) in enumerate(nodes):
        previous = struct.unpack_from("<Q", payload, 8)[0]
        expected = nodes[i - 1][0] if mode == "reverse" and i else 0
        if mode == "forward":
            expected = nodes[i + 1][0] if i + 1 < n else 0
        if expected:
            assert previous == expected
        else:
            assert previous not in blocks
    assert words[26] == n, ("object scans", words[26], n)
    assert words[28] == (n + 1 if mode == "reverse" else 2), words[28]
    assert words[27] >= n * words[28]
else:
    raise AssertionError(mode)
print(f"V09_HEAP_OK mode={mode} allocations={allocs} collections={collections} reclaimed={reclaimed} reused={reused} mapped={mapped} peak_live={words[23]} peak_roots={words[24]} scans={words[26]} headers={words[27]} passes={words[28]} sha256={hashlib.sha256(image).hexdigest()}")
