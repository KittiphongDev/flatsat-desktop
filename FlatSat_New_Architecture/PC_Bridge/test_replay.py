"""Offline replay tests for the bridge's reassembly + CRC (no hardware).
Run: python3 test_replay.py"""
import binascii
import gs_bridge as gb


def chunk(idx, total, data):
    return bytes([idx, total]) + data


def test_collector_completes_with_dupes():
    """c0 c0 c1 c1 c2 c2 -> exactly one completion, no phantom restart."""
    gb._collectors.clear()
    gb.schedule_broadcast = lambda *a, **k: None  # silence progress broadcasts
    gb.start_collect('eps', 0x0F)
    frames = [(0, 3, b'AAA'), (0, 3, b'AAA'), (1, 3, b'BBB'),
              (1, 3, b'BBB'), (2, 3, b'CCC'), (2, 3, b'CCC')]
    completes = []
    for i, t, d in frames:
        p = chunk(i, t, d)
        r = gb.collect_chunk('eps', p, len(p))
        if r is not None:
            completes.append(r)
    assert len(completes) == 1, f"expected 1 completion, got {len(completes)}"
    assert completes[0] == b'AAABBBCCC', completes[0]
    print("Test1 OK: collector completes once, dupes swallowed")


def test_collector_merges_across_retry():
    """A lost chunk on attempt 1 is filled by attempt 2 (re-request merge)."""
    gb._collectors.clear()
    gb.schedule_broadcast = lambda *a, **k: None
    gb.start_collect('eps', 0x0F)
    # Attempt 1: chunk 1 lost.
    for i, d in [(0, b'AAA'), (2, b'CCC')]:
        p = chunk(i, 3, d)
        assert gb.collect_chunk('eps', p, len(p)) is None
    # Attempt 2 (after a re-request): the missing chunk arrives.
    p = chunk(1, 3, b'BBB')
    blob = gb.collect_chunk('eps', p, len(p))
    assert blob == b'AAABBBCCC', blob
    print("Test2 OK: collector merges chunks across retries")


def test_log_collector_uint16():
    """uint16-chunked EPS log reassembles across the 255-chunk boundary."""
    gb.schedule_broadcast = lambda *a, **k: None
    gb._log_collector.update({"active": True, "chunks": {}, "total": None,
                              "retries": 0, "last": __import__('time').time()})
    total = 300  # > 255, needs uint16
    payloads = {}
    for i in range(total):
        data = bytes([i & 0xFF]) * 4
        payloads[i] = bytes([(i >> 8) & 0xFF, i & 0xFF,
                             (total >> 8) & 0xFF, total & 0xFF]) + data
    blob = None
    for i in range(total):
        blob = gb.collect_log_chunk(payloads[i], len(payloads[i]))
    assert blob is not None and len(blob) == total * 4, len(blob) if blob else None
    print("Test LOG OK: uint16 collector reassembles 300 chunks")


def test_crc_vector():
    data = b'\xAA\xBB\x01\x00'
    assert gb.calculate_crc32(data) == (binascii.crc32(data) & 0xFFFFFFFF)
    print("Test10 OK: CRC32 matches binascii")


def test_frame_budget():
    assert 24 + 2 + gb.IMAGE_CHUNK_SIZE <= 64
    assert gb.IMAGE_CHUNK_SIZE == 32
    print("F22 OK: frame budget within 64 bytes")


def test_parse_health():
    blob = bytes([2, 0x40, 1, 0x59, 0])
    devs = gb.parse_health(blob)
    assert len(devs) == 2 and devs[0]["online"] and not devs[1]["online"]
    assert devs[0]["addr"] == "0x40"
    print("Test HEALTH OK: parse + labels")


if __name__ == "__main__":
    test_collector_completes_with_dupes()
    test_collector_merges_across_retry()
    test_log_collector_uint16()
    test_crc_vector()
    test_frame_budget()
    test_parse_health()
    print("ALL PASS")
