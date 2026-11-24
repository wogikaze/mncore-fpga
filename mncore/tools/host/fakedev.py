"""Software model of the board protocol (brd_host_if + memories), used by tests and `--port fake`.

It behaves like a pyserial port: write() feeds request bytes, read() returns response bytes.
Command semantics follow mncore/rtl/board/PROTOCOL.md.  RUN does not execute instructions: it only
advances pc / steps (enough to test the host-side sequencing of .asm programs).
"""
from __future__ import annotations

from collections import defaultdict

from mnhost import CMD, crc8, SYNC

ST_OK, ST_E_CRC, ST_E_CMD, ST_E_LEN, ST_E_BUSY, ST_E_RANGE, ST_E_ARG = range(7)


class FakeDevice:
    def __init__(self, pbuf=2048, clk_hz=27_000_000, baud=1_000_000, imem_depth=64,
                 topo=(1, 1, 1, 1, 1), space_depth=None, design_id=0x7F, flags=0x01):
        self.pbuf = pbuf
        self.clk_hz = clk_hz
        self.div = (clk_hz * 256 + baud // 2) // baud
        self.imem_depth = imem_depth
        self.topo = topo
        self.space_depth = space_depth if space_depth is not None else {
            0x00: imem_depth * 8, 0x01: 1024, 0x02: 1024, 0x03: 256, 0x04: 256, 0x05: 8,
            0x06: 1024, 0x07: 4096, 0x08: 4096, 0x09: 65536, 0x0F: 8192, 0x10: 16}
        self.design_id, self.flags = design_id, flags
        self.mem = defaultdict(int)          # (space, loc, addr) -> long word
        self.baudrate = baud
        self._in = bytearray()
        self._out = bytearray()
        self.pc = self.steps = 0
        self.reason = self.info_word = 0
        self.runs = []                       # (start, count) log
        self.counters = [0, 0, 0, 0]
        self.corrupt_next_response = 0       # test hook: flip a bit in the next N responses
        self.stop_rule = None                # test hook: f(start, count) -> (reason, pc, info) or None

    # -- pyserial-like surface
    def write(self, data: bytes):
        self._in += data
        self._process()
        return len(data)

    def read(self, n: int = 1) -> bytes:
        out = bytes(self._out[:n])
        del self._out[:n]
        return out

    def reset_input_buffer(self):
        self._out.clear()

    # -- protocol
    def _process(self):
        while True:
            while self._in and self._in[0] != SYNC:
                del self._in[0]
            if len(self._in) < 4:
                return
            n = self._in[2] | (self._in[3] << 8)
            if len(self._in) < 5 + n:
                return
            frame = bytes(self._in[:5 + n])
            del self._in[:5 + n]
            cmd, payload = frame[1], frame[4:4 + n]
            if crc8(frame[1:4 + n]) != frame[4 + n]:
                self.counters[0] += 1
                self._respond(cmd, ST_E_CRC)
            elif n > self.pbuf:
                self._respond(cmd, ST_E_LEN)
            else:
                self._exec(cmd, payload)

    def _respond(self, cmd, status, body=b""):
        data = bytes([status]) + body
        f = bytearray([cmd | 0x80, len(data) & 0xFF, len(data) >> 8]) + data
        f.append(crc8(bytes(f)))
        if self.corrupt_next_response:
            self.corrupt_next_response -= 1
            f[-1] ^= 0x01
        self._out += bytes([SYNC]) + f

    def _valid(self, space, loc, addr):
        if space not in self.space_depth or addr >= self.space_depth[space] or addr >= 1 << 23:
            return False
        if space in (0x00, 0x0F):
            return loc == 0
        return True

    def _exec(self, cmd, p):
        u16 = lambda i: int.from_bytes(p[i:i + 2], "little")
        u32 = lambda i: int.from_bytes(p[i:i + 4], "little")
        if cmd == CMD["PING"]:
            return self._respond(cmd, ST_OK, p)
        if cmd == CMD["INFO"]:
            if p:
                return self._respond(cmd, ST_E_LEN)
            body = bytes([1, self.design_id]) + self.pbuf.to_bytes(2, "little")
            body += self.clk_hz.to_bytes(4, "little") + self.div.to_bytes(4, "little")
            body += self.imem_depth.to_bytes(2, "little") + bytes(self.topo) + bytes([self.flags])
            body += b"".join(self.space_depth.get(i, 0).to_bytes(4, "little") for i in range(16))
            body += (2048).to_bytes(2, "little") + (2048).to_bytes(2, "little")
            return self._respond(cmd, ST_OK, body)
        if cmd == CMD["STATUS"]:
            if p:
                return self._respond(cmd, ST_E_LEN)
            body = bytes([0, self.reason]) + self.pc.to_bytes(2, "little") + self.info_word.to_bytes(4, "little")
            body += self.steps.to_bytes(4, "little")
            body += b"".join(c.to_bytes(2, "little") for c in self.counters)
            body += (0).to_bytes(2, "little") + self.div.to_bytes(4, "little") + bytes([0])
            return self._respond(cmd, ST_OK, body)
        if cmd == CMD["RESET"]:
            if len(p) > 1:
                return self._respond(cmd, ST_E_LEN)
            self.pc = self.steps = 0
            if p and p[0] & 1:
                self.counters = [0, 0, 0, 0]
            return self._respond(cmd, ST_OK)
        if cmd == CMD["RUN"]:
            if len(p) != 6:
                return self._respond(cmd, ST_E_LEN)
            start, count = u16(0), u32(2)
            self.runs.append((start, count))
            self.pc, self.steps = start + count, count
            self.reason = self.info_word = 0
            stop = self.stop_rule(start, count) if self.stop_rule else None
            if stop:
                self.reason, self.pc, self.info_word = stop
                self.steps = self.pc - start
            return self._respond(cmd, ST_OK)
        if cmd == CMD["SET_BAUD"]:
            if len(p) != 4:
                return self._respond(cmd, ST_E_LEN)
            if u32(0) < 1024:
                return self._respond(cmd, ST_E_ARG)
            self.div = u32(0)
            return self._respond(cmd, ST_OK)
        if cmd == CMD["WR_MEM"]:
            if len(p) < 8 or len(p) % 8:
                return self._respond(cmd, ST_E_LEN)
            space, mask, loc, addr = p[0], p[1], u16(2), u32(4)
            bm = sum(0xFF << (8 * i) for i in range(8) if (mask >> i) & 1)
            for i in range((len(p) - 8) // 8):
                if not self._valid(space, loc, addr + i):
                    return self._respond(cmd, ST_E_RANGE, i.to_bytes(4, "little"))
                w = int.from_bytes(p[8 + 8 * i:16 + 8 * i], "little")
                k = (space, loc, addr + i)
                self.mem[k] = (self.mem[k] & ~bm) | (w & bm)
            return self._respond(cmd, ST_OK)
        if cmd == CMD["WR_IMEM"]:
            if len(p) < 2 or (len(p) - 2) % 56:
                return self._respond(cmd, ST_E_LEN)
            base = u16(0)
            for j in range((len(p) - 2) // 8):
                a = (base + j // 7) * 8 + j % 7
                if not self._valid(0, 0, a):
                    return self._respond(cmd, ST_E_RANGE, j.to_bytes(4, "little"))
                self.mem[(0, 0, a)] = int.from_bytes(p[2 + 8 * j:10 + 8 * j], "little")
            return self._respond(cmd, ST_OK)
        if cmd == CMD["RD_MEM"]:
            if len(p) != 10:
                return self._respond(cmd, ST_E_LEN)
            space, loc, addr, n = p[0], u16(2), u32(4), u16(8)
            if n * 8 > self.pbuf:
                return self._respond(cmd, ST_E_ARG)
            out = b""
            for i in range(n):
                if not self._valid(space, loc, addr + i):
                    return self._respond(cmd, ST_E_RANGE, i.to_bytes(4, "little"))
                out += self.mem[(space, loc, addr + i)].to_bytes(8, "little")
            return self._respond(cmd, ST_OK, out)
        return self._respond(cmd, ST_E_CMD)
