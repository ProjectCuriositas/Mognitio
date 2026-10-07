"""Independent, bounded reader for private native heap snapshot version 1."""
from pathlib import Path
import argparse
import json
import struct

LIMIT = 64 * 1024 * 1024


def read_snapshot(data, profile, point, ordinal, check_links=True):
    def require(ok, message):
        if not ok:
            raise ValueError(message)

    def word(at):
        require(0 <= at <= len(data) - 8, "truncated word")
        return struct.unpack_from("<Q", data, at)[0]

    require(72 <= len(data) <= LIMIT + 2048, "snapshot length")
    require(data[:8] == b"MGN11HS1", "snapshot magic")
    version, context_version, actual_profile, size, actual_point, actual_ordinal, count, mapped = (
        struct.unpack_from("<8Q", data, 8))
    require((version, context_version) == (1, 7), "snapshot version")
    require(profile in (0, 1) and actual_profile == profile, "profile mismatch")
    require(size == (304, 352)[profile], "context length")
    require((actual_point, actual_ordinal) == (point, ordinal), "capture mismatch")
    require(0 <= count <= 64 and mapped <= LIMIT, "arena limits")
    context = 72
    require(context + size <= len(data), "truncated context")
    head = word(context + (288, 336)[profile])
    arena_head, page = word(context + 8), word(context + 16)
    require(page >= 4096 and page & (page - 1) == 0, "page size")
    require(word(context + 72) == mapped, "mapped context mismatch")
    cursor = context + size
    arenas, blocks, free, geometry = [], {}, [], []
    total = 0
    expected_address = arena_head
    for index in range(count):
        address, length = word(cursor), word(cursor + 8)
        cursor += 16
        require(address != 0 and address == expected_address, "arena chain")
        require(address % page == 0 and length >= page and length % page == 0, "arena alignment")
        require(length <= LIMIT - total and cursor + length <= len(data), "arena length")
        require(address + length < 2**64, "arena overflow")
        require(all(address + length <= a or a + n <= address for a, n in arenas), "arena overlap")
        arenas.append((address, length))
        total += length
        require(word(cursor + 8) == length and word(cursor + 16) == 32 and word(cursor + 24) == 0,
                "arena header")
        expected_address = word(cursor)
        offset, previous_free = 32, False
        while offset < length:
            at = cursor + offset
            physical, flags, link, reserved = (word(at + n) for n in (0, 8, 16, 24))
            require(physical >= 32 and physical % 8 == 0 and offset + physical <= length,
                    "physical partition")
            require(flags in (0, 1, 17, 33, 49, 65, 81, 97), "block flags")
            require(not (previous_free and flags == 0), "uncoalesced free run")
            identity = (index, offset)
            blocks[address + offset] = dict(identity=identity, size=physical, flags=flags,
                                           link=link, file_offset=at)
            geometry.append((identity, physical, flags))
            if flags == 0:
                require(reserved == 0, "free reserved word")
                free.append(address + offset)
            previous_free = flags == 0
            offset += physical
        require(offset == length, "arena end")
        cursor += length
    require(total == mapped and expected_address == 0, "arena totals or terminator")
    require(cursor == len(data), "trailing bytes")
    free_set = set(free)
    reached = []
    visited = set()
    if check_links:
        pointer = head
        while pointer:
            require(pointer in free_set, "free pointer is not a free block start")
            require(pointer not in visited, "free cycle or duplicate")
            visited.add(pointer)
            reached.append(pointer)
            pointer = blocks[pointer]["link"]
        require(reached == free, "free head coverage or order")
    # Canonical geometry includes every observed next link; process addresses are
    # translated only for comparison, never used to repair a missing head.
    def canonical(pointer):
        if pointer == 0:
            return None
        require(pointer in blocks, "link outside physical partition")
        return blocks[pointer]["identity"]
    links = [(blocks[p]["identity"], canonical(blocks[p]["link"])) for p in free]
    return dict(profile=profile, point=point, ordinal=ordinal, mapped=mapped,
                arena_sizes=[n for _, n in arenas], geometry=geometry, links=links,
                head=head, free=free, blocks=blocks, context_offset=context,
                free_head_offset=context + (288, 336)[profile])


def negative_controls(data, profile, point, ordinal):
    good = read_snapshot(data, profile, point, ordinal)
    samples = [data[:240], data[:-1], data + b"x"]
    def changed(at, value):
        copy = bytearray(data)
        struct.pack_into("<Q", copy, at, value)
        return bytes(copy)
    samples += [changed(24, 1-profile), changed(32, 240), changed(8, 0), changed(16, 6)]
    free, blocks = good["free"], good["blocks"]
    if free:
        first = free[0]
        samples += [changed(good["free_head_offset"], 0),
                    changed(blocks[first]["file_offset"] + 16, first),
                    changed(blocks[first]["file_offset"] + 16, first + 8),
                    changed(blocks[first]["file_offset"] + 16, 8)]
        allocated = next((p for p, row in blocks.items() if row["flags"]), None)
        if allocated:
            samples.append(changed(blocks[first]["file_offset"] + 16, allocated))
    for sample in samples:
        try:
            read_snapshot(sample, profile, point, ordinal)
        except ValueError:
            continue
        raise AssertionError("reader accepted malformed snapshot")
    return len(samples)


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("snapshot", type=Path)
    parser.add_argument("--profile", type=int, required=True)
    parser.add_argument("--point", type=int, required=True)
    parser.add_argument("--ordinal", type=int, required=True)
    args = parser.parse_args()
    data = args.snapshot.read_bytes()
    row = read_snapshot(data, args.profile, args.point, args.ordinal)
    count = negative_controls(data, args.profile, args.point, args.ordinal)
    print(json.dumps(dict(mapped=row["mapped"], blocks=len(row["blocks"]),
                          free=len(row["free"]), reader_negatives=count)))


if __name__ == "__main__":
    main()
