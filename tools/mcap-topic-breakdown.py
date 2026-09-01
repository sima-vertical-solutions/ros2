#!/usr/bin/env python3
"""Per-topic payload breakdown of an MCAP bag (VP-15657).

Answers "what is actually in this bag, and what does each topic cost" --
message count, rate, total bytes and share of the bag, per topic.

It never decompresses a chunk. MCAP writes MessageIndex records *outside*
the chunks, and each one lists the byte offset of every message within the
chunk's uncompressed data. Sorting those offsets and taking deltas gives
each message's exact on-the-wire record size, so the whole breakdown comes
from the index alone -- seconds on a multi-GB bag instead of minutes, with
no zstd dependency.

Sizes are UNCOMPRESSED record sizes (what the recorder serialized and had
to move), which is the number that matters for CPU. The bag on disk is
smaller by the chunk compression ratio, reported at the end.

    ./mcap-topic-breakdown.py BAG.mcap
    ./mcap-topic-breakdown.py BAG.mcap --top 25
    ./mcap-topic-breakdown.py BAG.mcap --csv out.csv
"""

import argparse
import struct
import sys
from collections import defaultdict

MAGIC = b"\x89MCAP0\r\n"

OP_SCHEMA = 0x03
OP_CHANNEL = 0x04
OP_CHUNK_INDEX = 0x08
OP_MESSAGE_INDEX = 0x07
OP_STATISTICS = 0x0B
OP_FOOTER = 0x02


class Reader:
    """Cursor over a bytes buffer, in MCAP's little-endian encoding."""

    def __init__(self, buf, pos=0):
        self.buf = buf
        self.pos = pos

    def u16(self):
        v = struct.unpack_from("<H", self.buf, self.pos)[0]
        self.pos += 2
        return v

    def u32(self):
        v = struct.unpack_from("<I", self.buf, self.pos)[0]
        self.pos += 4
        return v

    def u64(self):
        v = struct.unpack_from("<Q", self.buf, self.pos)[0]
        self.pos += 8
        return v

    def string(self):
        n = self.u32()
        s = self.buf[self.pos:self.pos + n].decode("utf-8", "replace")
        self.pos += n
        return s

    def skip(self, n):
        self.pos += n


def read_footer(f, size):
    """Footer is the last record: 20-byte payload + 9-byte header, then magic."""
    f.seek(size - 8 - 20 - 9)
    op = f.read(1)[0]
    if op != OP_FOOTER:
        raise SystemExit(
            "No footer record -- the bag has no summary section "
            "(recorder likely died mid-write). Cannot index it cheaply."
        )
    struct.unpack("<Q", f.read(8))[0]  # record length
    summary_start = struct.unpack("<Q", f.read(8))[0]
    if summary_start == 0:
        raise SystemExit("Bag has an empty summary section; cannot index it cheaply.")
    return summary_start


def parse_summary(f, summary_start, size):
    """Read the summary section: channels, schemas, statistics, chunk indexes."""
    f.seek(summary_start)
    blob = f.read(size - summary_start)
    r = Reader(blob)

    schemas = {}        # schema_id -> type name
    channels = {}       # channel_id -> (topic, schema_id)
    chunk_indexes = []  # (message_index_offsets dict, uncompressed_size, compressed_size)
    stats = None

    end = len(blob) - 8 - 20 - 9  # stop before the footer record
    while r.pos < end:
        op = r.buf[r.pos]
        r.pos += 1
        length = r.u64()
        body_end = r.pos + length

        if op == OP_SCHEMA:
            sid = r.u16()
            name = r.string()
            schemas[sid] = name
        elif op == OP_CHANNEL:
            cid = r.u16()
            sid = r.u16()
            topic = r.string()
            channels[cid] = (topic, sid)
        elif op == OP_CHUNK_INDEX:
            r.u64()  # message_start_time
            r.u64()  # message_end_time
            r.u64()  # chunk_start_offset
            r.u64()  # chunk_length
            map_len = r.u32()
            map_end = r.pos + map_len
            offsets = {}
            while r.pos < map_end:
                ch = r.u16()
                offsets[ch] = r.u64()
            r.u64()  # message_index_length
            r.string()  # compression
            comp = r.u64()
            uncomp = r.u64()
            chunk_indexes.append((offsets, uncomp, comp))
        elif op == OP_STATISTICS:
            msg_count = r.u64()
            r.u16()   # schema_count
            r.u32()   # channel_count
            r.u32()   # attachment_count
            r.u32()   # metadata_count
            r.u32()   # chunk_count
            start_t = r.u64()
            end_t = r.u64()
            map_len = r.u32()
            map_end = r.pos + map_len
            per_channel = {}
            while r.pos < map_end:
                ch = r.u16()
                per_channel[ch] = r.u64()
            stats = (msg_count, start_t, end_t, per_channel)

        r.pos = body_end

    return schemas, channels, chunk_indexes, stats


def message_sizes(f, chunk_indexes):
    """Per-channel byte totals, from MessageIndex offset deltas.

    Every message in a chunk appears exactly once across that chunk's
    MessageIndex records. Sorting their offsets and differencing gives each
    record's length; the final message runs to the chunk's uncompressed end.
    """
    per_channel_bytes = defaultdict(int)
    per_channel_msgs = defaultdict(int)

    for offsets, uncomp, _comp in chunk_indexes:
        entries = []  # (offset_in_chunk, channel_id)
        for ch, file_off in offsets.items():
            f.seek(file_off)
            op = f.read(1)[0]
            if op != OP_MESSAGE_INDEX:
                continue
            length = struct.unpack("<Q", f.read(8))[0]
            r = Reader(f.read(length))
            cid = r.u16()
            arr_len = r.u32()
            arr_end = r.pos + arr_len
            while r.pos < arr_end:
                r.u64()          # log_time
                entries.append((r.u64(), cid))

        if not entries:
            continue
        entries.sort()
        for i, (off, cid) in enumerate(entries):
            nxt = entries[i + 1][0] if i + 1 < len(entries) else uncomp
            per_channel_bytes[cid] += max(0, nxt - off)
            per_channel_msgs[cid] += 1

    return per_channel_bytes, per_channel_msgs


def main():
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("bag")
    ap.add_argument("--top", type=int, default=0, help="show only the N largest topics")
    ap.add_argument("--csv", help="also write the full table as CSV")
    args = ap.parse_args()

    with open(args.bag, "rb") as f:
        if f.read(8) != MAGIC:
            raise SystemExit(f"{args.bag} is not an MCAP file.")
        f.seek(0, 2)
        size = f.tell()

        summary_start = read_footer(f, size)
        schemas, channels, chunk_indexes, stats = parse_summary(f, summary_start, size)
        by_bytes, by_msgs = message_sizes(f, chunk_indexes)

    if stats:
        _total_msgs, start_t, end_t, per_channel_counts = stats
        duration = (end_t - start_t) / 1e9
    else:
        duration = 0.0
        per_channel_counts = {}

    rows = []
    for cid, (topic, sid) in channels.items():
        nbytes = by_bytes.get(cid, 0)
        nmsgs = per_channel_counts.get(cid, by_msgs.get(cid, 0))
        if nmsgs == 0 and nbytes == 0:
            continue
        rows.append({
            "topic": topic,
            "type": schemas.get(sid, "?"),
            "msgs": nmsgs,
            "hz": nmsgs / duration if duration else 0.0,
            "bytes": nbytes,
            "mbps": nbytes / 1048576 / duration if duration else 0.0,
            "avg": nbytes / nmsgs if nmsgs else 0,
        })

    rows.sort(key=lambda r: r["bytes"], reverse=True)
    total_bytes = sum(r["bytes"] for r in rows)
    total_msgs = sum(r["msgs"] for r in rows)

    print(f"bag        : {args.bag}")
    print(f"on disk    : {size / 1073741824:.2f} GB")
    print(f"duration   : {duration:.1f} s ({duration / 60:.1f} min)")
    print(f"uncompressed payload : {total_bytes / 1073741824:.2f} GB "
          f"({total_bytes / 1048576 / duration:.2f} MB/s)" if duration else "")
    if total_bytes:
        print(f"compression ratio    : {total_bytes / size:.2f}x")
    print(f"topics     : {len(rows)},  messages: {total_msgs:,} "
          f"({total_msgs / duration:.0f}/s)" if duration else "")
    print()

    hdr = f"{'topic':<52} {'msgs':>9} {'Hz':>7} {'MB':>9} {'MB/s':>7} {'%':>6} {'avg B':>9}"
    print(hdr)
    print("-" * len(hdr))
    shown = rows[:args.top] if args.top else rows
    for r in shown:
        pct = 100 * r["bytes"] / total_bytes if total_bytes else 0
        print(f"{r['topic']:<52.52} {r['msgs']:>9,} {r['hz']:>7.1f} "
              f"{r['bytes'] / 1048576:>9.1f} {r['mbps']:>7.2f} {pct:>5.1f}% {r['avg']:>9,.0f}")

    if args.top and len(rows) > args.top:
        rest = rows[args.top:]
        rb = sum(x["bytes"] for x in rest)
        print(f"{'... ' + str(len(rest)) + ' more topics':<52} "
              f"{sum(x['msgs'] for x in rest):>9,} {'':>7} {rb / 1048576:>9.1f} "
              f"{rb / 1048576 / duration:>7.2f} {100 * rb / total_bytes:>5.1f}%")

    # Message-rate view: the baseline showed cost tracks message count, not bytes.
    print()
    print("by message rate (the driver of per-message recorder overhead)")
    print("-" * len(hdr))
    for r in sorted(rows, key=lambda x: x["msgs"], reverse=True)[:15]:
        pct = 100 * r["msgs"] / total_msgs if total_msgs else 0
        print(f"{r['topic']:<52.52} {r['msgs']:>9,} {r['hz']:>7.1f} "
              f"{r['bytes'] / 1048576:>9.1f} {'':>7} {pct:>5.1f}% {r['avg']:>9,.0f}")

    if args.csv:
        import csv
        with open(args.csv, "w", newline="") as fh:
            w = csv.DictWriter(fh, fieldnames=["topic", "type", "msgs", "hz",
                                               "bytes", "mbps", "avg"])
            w.writeheader()
            w.writerows(rows)
        print(f"\nCSV: {args.csv}", file=sys.stderr)


if __name__ == "__main__":
    main()
