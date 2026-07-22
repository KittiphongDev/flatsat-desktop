"""Offline replay tests for the bridge's reassembly + CRC (no hardware).
Run: python3 test_replay.py"""
import binascii
import gs_bridge as gb


def chunk(idx, total, data):
    return bytes([idx, total]) + data


def test_no_phantom_restart():
    """c0 c0 c1 c1 c2 c2 -> exactly one completion, no phantom restart (D2)."""
    gb._reassembly.clear()
    frames = [(0, 3, b'AAA'), (0, 3, b'AAA'), (1, 3, b'BBB'),
              (1, 3, b'BBB'), (2, 3, b'CCC'), (2, 3, b'CCC')]
    completes = []
    for i, t, d in frames:
        p = chunk(i, t, d)
        r = gb.reassemble('eps', p, len(p))
        if r is not None:
            completes.append(r)
    assert len(completes) == 1, f"expected 1 completion, got {len(completes)}"
    assert completes[0] == b'AAABBBCCC', completes[0]
    print("Test1 OK: single completion, no phantom restart")


def test_dup_health():
    """Single-chunk health sent twice -> one completion (D3)."""
    gb._reassembly.clear()
    p = chunk(0, 1, b'\x01\x40\x01')
    r1 = gb.reassemble('health', p, len(p))
    r2 = gb.reassemble('health', p, len(p))
    assert r1 == b'\x01\x40\x01' and r2 is None, (r1, r2)
    print("Test2 OK: duplicate single-chunk swallowed")


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
    test_no_phantom_restart()
    test_dup_health()
    test_crc_vector()
    test_frame_budget()
    test_parse_health()
    print("ALL PASS")
