#!/usr/bin/env python3
"""mnhost: host tool for the nano20k board protocol (see mncore/rtl/board/PROTOCOL.md).

  python mncore/tools/host/mnhost.py ping
  python mncore/tools/host/mnhost.py info
  python mncore/tools/host/mnhost.py write TEST 0 0x10 0123456789abcdef ...
  python mncore/tools/host/mnhost.py read TEST 0 0x10 4
  python mncore/tools/host/mnhost.py run prog.asm -o prog.ndmp      # assemble3 flat/no-packer output
  python mncore/tools/host/mnhost.py run --start 0 --count 100
  python mncore/tools/host/mnhost.py status
  python mncore/tools/host/mnhost.py bench --bauds 1000000,2000000,3000000
  python mncore/tools/host/mnhost.py bridge reboot     # BL616 UART bridge hung: reboot the debugger chip

Global options: --port COMx|auto|fake (default auto: VID:PID 0403:6010 = Tang Nano 20K BL616),
--baud (the rate the FPGA is currently using, default 1000000), --timeout seconds.
"""
from __future__ import annotations

import argparse
import os
import random
import re
import sys
import time
from dataclasses import dataclass, field

PROTO_VERSION = 1
SYNC = 0xA5

CMD = {
    "PING": 0x01, "INFO": 0x02, "WR_IMEM": 0x03, "WR_MEM": 0x04, "RD_MEM": 0x05,
    "RUN": 0x06, "STATUS": 0x07, "RESET": 0x08, "SET_BAUD": 0x09,
}
STATUS_NAMES = {0: "OK", 1: "E_CRC", 2: "E_CMD", 3: "E_LEN", 4: "E_BUSY", 5: "E_RANGE", 6: "E_ARG"}
REASON_NAMES = {0: "OK", 1: "E_RANGE", 2: "E_UNSUPPORTED", 3: "E_DECODE"}

SPACES = {
    "IMEM": 0x00, "LM0": 0x01, "LM1": 0x02, "GRF0": 0x03, "GRF1": 0x04, "T": 0x05,
    "L1BM": 0x06, "L2BM": 0x07, "PDM": 0x08, "DRAM": 0x09, "TEST": 0x0F,
}
SPACE_BY_ID = {v: k for k, v in SPACES.items()}

# chip topology (MN-Core 2): 4 groups x 2 L2B x 8 L1B x 16 MAB x 4 PE
CHIP_DIMS = (("n", 4), ("c", 2), ("b", 8), ("m", 16), ("p", 4))
LOC_SHIFT = {"n": 10, "c": 9, "b": 6, "m": 2, "p": 0}
LOC_MASK = {"n": 3, "c": 1, "b": 7, "m": 15, "p": 3}

IMEM_LANES = 7                  # 448-bit entry = 7 long words
IMEM_TYPE_J = 1
IMEM_TYPE_M = 2
MASK64 = (1 << 64) - 1

BL616_VID_PID = (0x0403, 0x6010)


# ----------------------------------------------------------------------------- framing
def _crc8_table():
    t = []
    for b in range(256):
        x = b
        for _ in range(8):
            x = ((x << 1) ^ 0x07) & 0xFF if x & 0x80 else (x << 1) & 0xFF
        t.append(x)
    return t


_CRC8 = _crc8_table()


def crc8(data: bytes, crc: int = 0) -> int:
    """CRC-8/SMBUS: poly 0x07, init 0, no reflection, no final xor.  crc8(b"123456789") == 0xF4."""
    for b in data:
        crc = _CRC8[crc ^ b]
    return crc


def encode_frame(cmd: int, payload: bytes = b"") -> bytes:
    body = bytes([cmd, len(payload) & 0xFF, len(payload) >> 8]) + payload
    return bytes([SYNC]) + body + bytes([crc8(body)])


def loc_code(n=0, c=0, b=0, m=0, p=0) -> int:
    return (n << 10) | (c << 9) | (b << 6) | (m << 2) | p


def loc_fields(code: int) -> dict:
    return {k: (code >> LOC_SHIFT[k]) & LOC_MASK[k] for k, _ in CHIP_DIMS}


def parse_loc(text: str) -> int:
    """'n0c0b0m0p1' (any subset, missing = 0) or an integer."""
    text = text.strip()
    if re.fullmatch(r"(0x[0-9a-fA-F]+|\d+)", text):
        return int(text, 0)
    f = dict.fromkeys("ncbmp", 0)
    for k, v in re.findall(r"([ncbmp])(\d+)", text):
        f[k] = int(v)
    return loc_code(**f)


def parse_space(text: str) -> int:
    t = text.strip().upper()
    if t in SPACES:
        return SPACES[t]
    return int(text, 0)


class ProtocolError(Exception):
    """Link-level failure: timeout, bad sync, bad CRC in a response."""


class DeviceError(Exception):
    """The device answered with a non-OK status."""

    def __init__(self, cmd: int, status: int, body: bytes):
        self.cmd, self.status, self.body = cmd, status, body
        name = STATUS_NAMES.get(status, f"0x{status:02x}")
        extra = f" info={int.from_bytes(body[:4], 'little')}" if len(body) >= 4 else ""
        super().__init__(f"cmd 0x{cmd:02x}: {name}{extra}")


# ----------------------------------------------------------------------------- link
def find_port() -> str:
    from serial.tools import list_ports
    cands = [p for p in list_ports.comports() if (p.vid, p.pid) == BL616_VID_PID]
    if not cands:
        raise SystemExit("no Tang Nano 20K UART found (VID:PID 0403:6010); use --port")
    # the BL616 exposes JTAG (interface A, WinUSB) and UART (interface B, COM port); prefer ...B serials
    cands.sort(key=lambda p: (not (p.serial_number or "").endswith("B"), p.device))
    return cands[0].device


class Link:
    """Frames over a serial-like object (pyserial or FakeDevice)."""

    def __init__(self, ser, verbose: bool = False):
        self.ser = ser
        self.verbose = verbose
        self.stats = {"tx_bytes": 0, "rx_bytes": 0, "retries": 0}

    @classmethod
    def open(cls, port: str | None, baud: int, timeout: float = 1.0, verbose: bool = False):
        if port == "fake":
            from fakedev import FakeDevice
            return cls(FakeDevice(), verbose)
        import serial
        port = port if port and port != "auto" else find_port()
        ser = serial.Serial(port, baudrate=baud, timeout=timeout, write_timeout=10)
        if hasattr(ser, "set_buffer_size"):
            try:
                ser.set_buffer_size(rx_size=1 << 20, tx_size=1 << 18)
            except Exception:
                pass
        return cls(ser, verbose)

    @property
    def baudrate(self) -> int:
        return self.ser.baudrate

    def set_host_baud(self, baud: int):
        self.ser.baudrate = baud

    def flush_input(self, settle: float = 0.03):
        time.sleep(settle)
        self.ser.reset_input_buffer()

    def send(self, cmd: int, payload: bytes = b""):
        f = encode_frame(cmd, payload)
        if self.verbose:
            print(f"> {f[:24].hex()}{'..' if len(f) > 24 else ''} ({len(f)} B)", file=sys.stderr)
        self.ser.write(f)
        self.stats["tx_bytes"] += len(f)

    def _read_exact(self, n: int, deadline: float) -> bytes:
        buf = bytearray()
        while len(buf) < n:
            if time.monotonic() > deadline:
                raise ProtocolError(f"timeout ({len(buf)}/{n} bytes)")
            chunk = self.ser.read(n - len(buf))
            buf += chunk
        return bytes(buf)

    def recv(self, timeout: float = 2.0) -> tuple[int, bytes]:
        deadline = time.monotonic() + timeout
        skipped = 0
        while True:
            b = self._read_exact(1, deadline)
            if b[0] == SYNC:
                break
            skipped += 1
        hdr = self._read_exact(3, deadline)
        n = hdr[1] | (hdr[2] << 8)
        rest = self._read_exact(n + 1, deadline)
        self.stats["rx_bytes"] += 4 + n + 1 + skipped
        if crc8(hdr + rest[:n]) != rest[n]:
            raise ProtocolError("bad CRC in response")
        if self.verbose:
            print(f"< {hdr[0]:02x} len={n} {rest[:16].hex()}{'..' if n > 16 else ''}"
                  f"{f' (skipped {skipped})' if skipped else ''}", file=sys.stderr)
        return hdr[0], rest[:n]

    def transact(self, cmd: int, payload: bytes = b"", timeout: float = 2.0, retries: int = 2,
                 check: bool = True) -> tuple[int, bytes]:
        """Send one frame and wait for its response.  Returns (status, body)."""
        for attempt in range(retries + 1):
            try:
                self.send(cmd, payload)
                rcmd, data = self.recv(timeout)
                if rcmd != (cmd | 0x80):
                    raise ProtocolError(f"response cmd 0x{rcmd:02x} for 0x{cmd:02x}")
                if not data:
                    raise ProtocolError("empty response")
                status, body = data[0], data[1:]
                if status == 1 and attempt < retries:            # E_CRC: the request was damaged
                    raise ProtocolError("device reported E_CRC")
                if check and status != 0:
                    raise DeviceError(cmd, status, body)
                return status, body
            except ProtocolError as e:
                if attempt >= retries or cmd == CMD["RUN"]:
                    raise
                self.stats["retries"] += 1
                if self.verbose:
                    print(f"  retry after: {e}", file=sys.stderr)
                self.flush_input(0.05)                            # > device inter-byte timeout (20 ms)
        raise AssertionError("unreachable")


# ----------------------------------------------------------------------------- device
@dataclass
class Info:
    proto: int
    design_id: int
    pbuf: int
    clk_hz: int
    div_q8: int
    imem_depth: int
    topo: tuple
    flags: int
    space_depth: dict
    rxfifo: int
    txfifo: int

    @property
    def baud(self) -> float:
        return self.clk_hz * 256.0 / self.div_q8


@dataclass
class Status:
    busy: bool
    reason: int
    pc: int
    info: int
    steps: int
    crc_err: int
    frame_err: int
    overrun: int
    timeout: int
    meas: int
    div_q8: int
    probation: bool

    @property
    def reason_name(self) -> str:
        return REASON_NAMES.get(self.reason, f"0x{self.reason:02x}")


class Device:
    def __init__(self, link: Link):
        self.link = link
        self._info: Info | None = None

    # -- basic commands
    def ping(self, data: bytes = b"") -> bytes:
        _, body = self.link.transact(CMD["PING"], data)
        if body != data:
            raise ProtocolError("PING echo mismatch")
        return body

    def info(self, refresh: bool = False) -> Info:
        if self._info is None or refresh:
            _, b = self.link.transact(CMD["INFO"])
            if len(b) < 88:
                raise ProtocolError(f"INFO too short ({len(b)})")
            u16 = lambda i: int.from_bytes(b[i:i + 2], "little")
            u32 = lambda i: int.from_bytes(b[i:i + 4], "little")
            depth = {i: u32(20 + 4 * i) for i in range(16)}
            self._info = Info(proto=b[0], design_id=b[1], pbuf=u16(2), clk_hz=u32(4), div_q8=u32(8),
                              imem_depth=u16(12), topo=tuple(b[14:19]), flags=b[19],
                              space_depth={k: v for k, v in depth.items() if v},
                              rxfifo=u16(84), txfifo=u16(86))
            if self._info.proto != PROTO_VERSION:
                raise ProtocolError(f"protocol version {self._info.proto}, tool speaks {PROTO_VERSION}")
        return self._info

    def status(self) -> Status:
        _, b = self.link.transact(CMD["STATUS"])
        u16 = lambda i: int.from_bytes(b[i:i + 2], "little")
        u32 = lambda i: int.from_bytes(b[i:i + 4], "little")
        return Status(busy=bool(b[0] & 1), reason=b[1], pc=u16(2), info=u32(4), steps=u32(8),
                      crc_err=u16(12), frame_err=u16(14), overrun=u16(16), timeout=u16(18),
                      meas=u16(20), div_q8=u32(22), probation=bool(b[26] & 1))

    def reset(self, clear_counters: bool = False):
        self.link.transact(CMD["RESET"], bytes([1]) if clear_counters else b"")

    def run(self, start: int, count: int):
        self.link.transact(CMD["RUN"], start.to_bytes(2, "little") + count.to_bytes(4, "little"))

    def wait_idle(self, timeout: float = 10.0, poll: float = 0.0) -> Status:
        deadline = time.monotonic() + timeout
        while True:
            st = self.status()
            if not st.busy:
                return st
            if time.monotonic() > deadline:
                raise ProtocolError(f"core still running after {timeout} s (pc={st.pc})")
            if poll:
                time.sleep(poll)

    # -- memory
    def _max_words(self) -> int:
        return (self.info().pbuf - 8) // 8

    def write(self, space: int, loc: int, addr: int, words, mask: int = 0xFF, window: int = 0):
        """Write long words (ints).  Splits into frames that fit the device payload buffer."""
        words = list(words)
        step = self._max_words()
        frames = []
        for i in range(0, len(words), step):
            chunk = words[i:i + step]
            pl = bytes([space, mask]) + loc.to_bytes(2, "little") + (addr + i).to_bytes(4, "little")
            pl += b"".join((w & MASK64).to_bytes(8, "little") for w in chunk)
            frames.append(pl)
        self._pipeline(CMD["WR_MEM"], frames, [1] * len(frames), window)

    def read(self, space: int, loc: int, addr: int, n: int, window: int = 0) -> list[int]:
        step = self.info().pbuf // 8
        frames, lens = [], []
        for i in range(0, n, step):
            k = min(step, n - i)
            frames.append(bytes([space, 0]) + loc.to_bytes(2, "little") + (addr + i).to_bytes(4, "little")
                          + k.to_bytes(2, "little"))
            lens.append(1 + 8 * k)
        out = []
        for body in self._pipeline(CMD["RD_MEM"], frames, lens, window):
            out += [int.from_bytes(body[j:j + 8], "little") for j in range(0, len(body), 8)]
        return out

    def write_imem(self, addr: int, entries, window: int = 0):
        """entries: 448-bit ints (see imem_entry)."""
        entries = list(entries)
        step = (self.info().pbuf - 2) // (8 * IMEM_LANES)
        frames = []
        for i in range(0, len(entries), step):
            pl = (addr + i).to_bytes(2, "little")
            for e in entries[i:i + step]:
                pl += b"".join(((e >> (64 * k)) & MASK64).to_bytes(8, "little") for k in range(IMEM_LANES))
            frames.append(pl)
        self._pipeline(CMD["WR_IMEM"], frames, [1] * len(frames), window)

    def _pipeline(self, cmd: int, frames: list[bytes], resp_lens: list[int], window: int) -> list[bytes]:
        """Send several frames before reading their responses (window > 0), or stop-and-wait (window = 0).

        A frame may go out while either
          (A) the request bytes in flight fit the FPGA receive FIFO (it can never overflow), or
          (B) the response bytes in flight fit the FPGA transmit FIFO (the FPGA never stalls on output,
              so it drains its receive FIFO at line rate),
        and in any case the response bytes in flight stay <= `window`.  The last cap protects the BL616
        USB bridge, which drops FPGA->host data when more than about 8 KB is queued (see WP-04 report)."""
        if window <= 0 or len(frames) <= 1:
            return [self.link.transact(cmd, f)[1] for f in frames]
        inf = self.info()
        bodies: list[bytes] = []
        inflight: list[tuple[int, int]] = []      # (request bytes, response bytes) per frame
        nxt = 0

        def can_send(req, rsp):
            if not inflight:
                return True
            q = sum(r for r, _ in inflight) + req
            s = sum(r for _, r in inflight) + rsp
            return s <= window and (q <= inf.rxfifo or s <= inf.txfifo)

        try:
            while len(bodies) < len(frames):
                while nxt < len(frames) and can_send(len(frames[nxt]) + 5, resp_lens[nxt] + 5):
                    self.link.send(cmd, frames[nxt])
                    inflight.append((len(frames[nxt]) + 5, resp_lens[nxt] + 5))
                    nxt += 1
                rcmd, data = self.link.recv(timeout=2.0 + 0.0001 * sum(resp_lens))
                if rcmd != (cmd | 0x80) or not data:
                    raise ProtocolError("unexpected response in pipeline")
                if data[0] != 0:
                    raise DeviceError(cmd, data[0], data[1:])
                bodies.append(data[1:])
                inflight.pop(0)
        except (ProtocolError, DeviceError) as e:
            if isinstance(e, DeviceError) and e.status != 1:
                raise
            # fall back to stop-and-wait for everything (writes and reads are idempotent)
            self.link.stats["retries"] += 1
            self.link.stats["last_error"] = f"pipeline: {e}"
            if self.link.verbose:
                print(f"  pipeline fallback: {e}", file=sys.stderr)
            self.link.flush_input(0.1)
            return [self.link.transact(cmd, f)[1] for f in frames]
        return bodies

    # -- baud rate
    # The STATUS request ends with its CRC byte 0x16; in that byte the last 0->1 edge is the start of the
    # stop bit, 9 bit times after the start edge.  STATUS.meas therefore measures 9 of the host's bits.
    STATUS_CRC_RISE_BITS = 9

    def measure_host_bit(self, n: int = 16) -> float:
        """Average bit period of the host -> FPGA direction, in FPGA clocks."""
        assert crc8(bytes([CMD["STATUS"], 0, 0])) == 0x16
        ms = [self.status().meas for _ in range(n)]
        return sum(ms) / len(ms) / self.STATUS_CRC_RISE_BITS

    def _switch(self, div: int, host_baud: int, verify_bytes: int):
        old = self.link.baudrate
        self.link.transact(CMD["SET_BAUD"], div.to_bytes(4, "little"))
        time.sleep(0.002)                      # let the OK response leave before re-clocking the host
        self.link.set_host_baud(host_baud)
        try:
            self.link.flush_input(0.01)
            data = bytes(random.getrandbits(8) for _ in range(verify_bytes))
            self.ping(data)                    # first good frame commits the new rate on the device
        except (ProtocolError, DeviceError):
            self.link.set_host_baud(old)
            time.sleep(1.5)                    # device reverts after its probation time (1 s)
            self.link.flush_input()
            self.ping()
            raise ProtocolError(f"{host_baud} baud (div {div / 256:.3f}) did not work; reverted to {old}")
        self._info = None

    def set_baud(self, baud: int, verify_bytes: int = 256, calibrate: bool = True) -> float:
        """Switch device and host to `baud`; returns the FPGA's rate.  Reverts on failure.

        calibrate: measure the bridge's real bit period (STATUS.meas) and, when it differs from the nominal
        rate by more than 0.3 %, retune the FPGA divider to it (the BL616 only makes some rates exactly)."""
        clk = self.info().clk_hz
        div = round(clk * 256 / baud)
        self._switch(div, baud, verify_bytes)
        if calibrate:
            bit = self.measure_host_bit()
            cal = round(bit * 256)
            if abs(cal - div) > 0.003 * div:
                self._switch(cal, baud, verify_bytes)
                div = cal
        return clk * 256.0 / div


# ----------------------------------------------------------------------------- .asm programs
def imem_entry(kind: str, word: int) -> int:
    t = IMEM_TYPE_J if kind == "j" else IMEM_TYPE_M
    return (t << 446) | word


@dataclass
class DOp:
    op: str                 # "set" or "get"
    space: str              # LM0 LM1 GRF0 GRF1 T L1BM L2BM PDM DRAM
    width: str              # "w" (32-bit word), "l" (long), "ll" (2 long words)
    addr: int               # as written: word address for r/s/m/n, long-word address otherwise
    loc: dict               # specified fields only, e.g. {"n": 0, "c": 0}
    count: int
    payload: list = field(default_factory=list)   # long words (set)
    text: str = ""


@dataclass
class AsmProgram:
    entries: list = field(default_factory=list)  # 448-bit IMEM entries in program order
    events: list = field(default_factory=list)   # (position in entries, DOp)


MEM_LETTER = {"r": "GRF0", "s": "GRF1", "m": "LM0", "n": "LM1", "t": "T", "b": "L1BM", "c": "L2BM",
              "p": "PDM", "d": "DRAM"}
SPACE_LEVEL = {"LM0": 5, "LM1": 5, "GRF0": 5, "GRF1": 5, "T": 5, "L1BM": 3, "L2BM": 2, "PDM": 1, "DRAM": 1}
MEM_RE = re.compile(r"^\$(ll|l)?([rsmntbcpd])(\d*)((?:[ncbmp]\d+)*)$")
D_RE = re.compile(r"^d\s+(set|get[dfh]?)\s+(\S+)\s+(\d+)\s*(.*)$")


def parse_payload(text: str) -> list[int]:
    """SDM 3.4.4 payload: 16-digit hex groups, or l / s / h sugar."""
    text = text.replace(" ", "")
    if not text:
        return []
    if re.fullmatch(r"[0-9a-fA-F]+", text):
        if len(text) % 16:
            raise ValueError(f"payload length {len(text)} is not a multiple of 16 hex digits")
        return [int(text[i:i + 16], 16) for i in range(0, len(text), 16)]
    out = []
    for kind, body in re.findall(r"([lsh])([0-9a-fA-F_]+)", text):
        parts = [int(x, 16) for x in body.split("_")]
        if kind == "l":
            out.append(parts[0])
        elif kind == "s":
            out.append((parts[0] << 32) | parts[1])
        else:
            out.append((parts[0] << 48) | (parts[1] << 32) | (parts[2] << 16) | parts[3])
    return out


def parse_dline(line: str) -> DOp:
    body = line.split("#", 1)[0].strip()
    m = D_RE.match(body)
    if not m:
        raise ValueError(f"cannot parse: {line}")
    op, mem, cnt, rest = m.groups()
    mm = MEM_RE.match(mem)
    if not mm:
        raise ValueError(f"cannot parse memory operand {mem!r}")
    pre, letter, addr, loc = mm.groups()
    space = MEM_LETTER[letter]
    if letter in "rsmn":
        width = {None: "w", "l": "l", "ll": "ll"}[pre]
    elif letter in "tb":
        width = "ll" if pre == "ll" else "l"
    else:
        width = "l"
    d = DOp(op="set" if op == "set" else "get", space=space, width=width, addr=int(addr or 0),
            loc={k: int(v) for k, v in re.findall(r"([ncbmp])(\d+)", loc)}, count=int(cnt), text=body)
    if d.op == "set":
        d.payload = parse_payload(rest)
        need = d.count * (2 if width == "ll" else 1)
        if len(d.payload) != need:
            raise ValueError(f"payload has {len(d.payload)} long words, expected {need}: {line}")
    return d


def parse_asm(text: str) -> AsmProgram:
    prog = AsmProgram()
    for ln, raw in enumerate(text.splitlines(), 1):
        line = raw.strip()
        if not line or line.startswith("#"):
            continue
        tag = line[0]
        if tag in "jm" and len(line) > 2 and line[1] == " ":
            bits = line[2:].strip()
            want = 426 if tag == "j" else 82
            if len(bits) != want or set(bits) - {"0", "1"}:
                raise ValueError(f"line {ln}: {tag} word must be {want} binary digits")
            prog.entries.append(imem_entry(tag, int(bits, 2)))
        elif tag == "d":
            prog.events.append((len(prog.entries), parse_dline(line)))
        elif tag in "iq":
            raise ValueError(f"line {ln}: '{tag}' words are not supported (use --instruction-mode flat "
                             f"--disable-packer)")
        else:
            raise ValueError(f"line {ln}: unknown line type {line[:20]!r}")
    return prog


@dataclass
class Topology:
    counts: tuple = (1, 1, 1, 1, 1)     # implemented n, c, b, m, p (from 0 in each dimension)

    def locations(self, space: str, spec: dict):
        level = SPACE_LEVEL[space]
        ranges = []
        for (k, _), cnt in list(zip(CHIP_DIMS, self.counts))[:level]:
            if k in spec:
                ranges.append([spec[k]] if spec[k] < cnt else [])
            else:
                ranges.append(range(cnt))
        out = [{}]
        for (k, _), r in zip(CHIP_DIMS, ranges):
            out = [dict(d, **{k: v}) for d in out for v in r]
        return out


def loc_text(space: str, f: dict) -> str:
    return "".join(f"{k}{f[k]}" for k, _ in CHIP_DIMS[:SPACE_LEVEL[space]])


class SpaceMap:
    """Maps (space, loc, long-word addr) to a device request.  Identity for a real core."""

    def target(self, space: str, f: dict, lw: int) -> tuple[int, int, int]:
        return SPACES[space], loc_code(**f), lw


class TestSpaceMap(SpaceMap):
    """Board-test smoke test: every space lives in a window of the TEST memory (single location)."""
    BASE = {"LM0": 0, "LM1": 1024, "GRF0": 2048, "GRF1": 2560, "T": 3072, "L1BM": 3584, "L2BM": 4608,
            "PDM": 6144, "DRAM": 7168}

    def target(self, space, f, lw):
        return SPACES["TEST"], 0, self.BASE[space] + lw


def long_words(d: DOp) -> list[tuple[int, int, int]]:
    """(long-word address, value, byte mask) for each long word touched by a d set / d get.

    For d get the value/mask fields are unused (value 0, mask 0xFF)."""
    out = []
    if d.space == "T":
        # T: 4 cycles x 2 long words; long-word index = 2 * cycle + half (half 0 = MSB side)
        for i in range(d.count):
            if d.width == "ll":
                out.append((2 * i, d.payload[2 * i] if d.payload else 0, 0xFF))
                out.append((2 * i + 1, d.payload[2 * i + 1] if d.payload else 0, 0xFF))
            else:
                out.append((2 * i, d.payload[i] if d.payload else 0, 0xFF))
    elif d.width == "w":
        # 32-bit words: word w is the MSB half of long word w//2 when w is even (SDM 3.4.4 example 3)
        for i in range(d.count):
            w = d.addr + i
            v = (d.payload[i] >> 32) if d.payload else 0
            out.append((w >> 1, (v << 32) if w % 2 == 0 else v, 0xF0 if w % 2 == 0 else 0x0F))
    else:
        per = 2 if d.width == "ll" else 1
        base = d.addr >> 1 if d.space in ("LM0", "LM1", "GRF0", "GRF1") else d.addr
        for i in range(d.count * per):
            out.append((base + i, d.payload[i] if d.payload else 0, 0xFF))
    return out


def _runs(items):
    """Group (addr, value, mask) into runs of consecutive addresses with the same mask."""
    merged: dict[int, list] = {}
    for a, v, m in items:
        if a in merged:
            ov, om = merged[a]
            bm = sum(0xFF << (8 * i) for i in range(8) if (m >> i) & 1)
            merged[a] = [(ov & ~bm) | (v & bm), om | m]
        else:
            merged[a] = [v, m]
    run = []
    for a in sorted(merged):
        v, m = merged[a]
        if run and a == run[-1][0] + 1 and m == run[-1][2]:
            run.append((a, v, m))
        else:
            if run:
                yield run
            run = [(a, v, m)]
    if run:
        yield run


def run_program(dev: Device, prog: AsmProgram, topo: Topology, smap: SpaceMap | None = None,
                run_timeout: float = 30.0, log=None) -> tuple[list[str], Status | None]:
    """Execute a parsed .asm: IMEM load, RUN segments split at d lines, d set -> WR_MEM, d get -> RD_MEM.
    Returns (ndmp lines, failing status or None)."""
    smap = smap or SpaceMap()
    inf = dev.info()
    depth = inf.imem_depth
    lines: list[str] = []
    dev.reset()
    win = {"base": None}

    def load_window(base):
        chunk = prog.entries[base:base + depth]
        dev.write_imem(0, chunk)
        win["base"] = base

    def run_range(a, b):
        while a < b:
            if depth == 0:
                raise SystemExit("device has no instruction memory")
            if win["base"] is None or not (win["base"] <= a < win["base"] + depth):
                load_window(a)
            n = min(b, win["base"] + depth) - a
            dev.run(a - win["base"], n)
            st = dev.wait_idle(run_timeout)
            if st.reason != 0:
                return st
            a += n
        return None

    if prog.entries:
        load_window(0)
    pc = 0
    for pos, d in prog.events:
        if pos > pc:
            st = run_range(pc, pos)
            if st is not None:
                return sorted(lines), st
            pc = pos
        if log:
            log(f"[{pos}] {d.text}")
        for f in topo.locations(d.space, d.loc):
            words = long_words(d)
            if d.op == "set":
                for run in _runs(words):
                    sp, lc, a0 = smap.target(d.space, f, run[0][0])
                    dev.write(sp, lc, a0, [v for _, v, _ in run], mask=run[0][2])
            else:
                addrs = sorted({a for a, _, _ in words})
                lo, hi = addrs[0], addrs[-1]
                sp, lc, a0 = smap.target(d.space, f, lo)
                vals = dev.read(sp, lc, a0, hi - lo + 1)
                for a in addrs:
                    lines.append(f"{d.space} {loc_text(d.space, f)} 0x{a:04x} {vals[a - lo]:016x}")
    if len(prog.entries) > pc:
        st = run_range(pc, len(prog.entries))
        if st is not None:
            return sorted(lines), st
    return sorted(lines), None


# ----------------------------------------------------------------------------- CLI
def connect(a) -> Device:
    link = Link.open(a.port, a.baud, timeout=0.2, verbose=a.verbose)
    dev = Device(link)
    return dev


def cmd_ping(dev, a):
    t0 = time.perf_counter()
    for _ in range(a.count):
        dev.ping(bytes(random.getrandbits(8) for _ in range(a.size)))
    dt = (time.perf_counter() - t0) / a.count
    print(f"PING ok: {a.count} x {a.size} B payload, {dt * 1000:.2f} ms per round trip")


def cmd_info(dev, a):
    i = dev.info()
    print(f"protocol v{i.proto}  design 0x{i.design_id:02x}  flags 0x{i.flags:02x}")
    print(f"clock {i.clk_hz} Hz  div {i.div_q8 / 256:.3f} clk/bit = {i.baud:.0f} baud")
    print(f"payload buffer {i.pbuf} B  rx fifo {i.rxfifo} B  tx fifo {i.txfifo} B  imem {i.imem_depth} entries")
    print("topology n/c/b/m/p = " + "/".join(str(x) for x in i.topo))
    for sid, dep in sorted(i.space_depth.items()):
        print(f"  space 0x{sid:02x} {SPACE_BY_ID.get(sid, '?'):5s} {dep} long words")


def cmd_status(dev, a):
    s = dev.status()
    print(f"core {'RUNNING' if s.busy else 'idle'}  reason {s.reason_name}  pc {s.pc}  info {s.info}  "
          f"steps {s.steps}")
    print(f"link: crc_err {s.crc_err}  frame_err {s.frame_err}  overrun {s.overrun}  timeout {s.timeout}  "
          f"div {s.div_q8 / 256:.3f}  meas {s.meas}{'  (probation)' if s.probation else ''}")


def cmd_reset(dev, a):
    dev.reset(a.clear)
    print("RESET ok")


def cmd_write(dev, a):
    sp, lc = parse_space(a.space), parse_loc(a.loc)
    if a.file:
        data = open(a.file, "rb").read()
        data += b"\0" * (-len(data) % 8)
        words = [int.from_bytes(data[i:i + 8], "little") for i in range(0, len(data), 8)]
    else:
        words = [int(w, 16) for w in a.values]
    dev.write(sp, lc, int(a.addr, 0), words, mask=int(a.mask, 16), window=a.window)
    print(f"wrote {len(words)} long words")


def cmd_read(dev, a):
    sp, lc = parse_space(a.space), parse_loc(a.loc)
    addr = int(a.addr, 0)
    vals = dev.read(sp, lc, addr, a.n, window=a.window)
    name = SPACE_BY_ID.get(sp, f"S{sp:02x}")
    f = loc_fields(lc)
    loc = "".join(f"{k}{f[k]}" for k, _ in CHIP_DIMS[:SPACE_LEVEL.get(name, 5)])
    for i, v in enumerate(vals):
        print(f"{name} {loc} 0x{addr + i:04x} {v:016x}")


def cmd_run(dev, a):
    if a.asm is None:
        if a.count is None:
            raise SystemExit("run: give an .asm file or --start/--count")
        dev.run(a.start, a.count)
        if a.no_wait:
            print("RUN started")
            return
        st = dev.wait_idle(a.run_timeout)
        print(f"RUN done: reason {st.reason_name} pc {st.pc} steps {st.steps} info {st.info}")
        if st.reason:
            sys.exit(2)
        return
    prog = parse_asm(open(a.asm, encoding="utf-8").read())
    inf = dev.info()
    topo = Topology(tuple(int(x) for x in a.topo.split(","))) if a.topo else Topology(inf.topo)
    smap = TestSpaceMap() if a.map_test else SpaceMap()
    if a.map_test and not a.topo:
        topo = Topology((1, 1, 1, 1, 1))
    log = (lambda s: print(s, file=sys.stderr)) if a.verbose else None
    lines, st = run_program(dev, prog, topo, smap, a.run_timeout, log)
    out = "# ndmp v1\n" + "".join(l + "\n" for l in lines)
    if a.output:
        with open(a.output, "w", encoding="utf-8", newline="\n") as fh:
            fh.write(out)
    else:
        sys.stdout.write(out)
    print(f"{len(prog.entries)} entries, {len(prog.events)} d lines, {len(lines)} ndmp lines", file=sys.stderr)
    if st is not None:
        print(f"STOPPED: {st.reason_name} pc {st.pc} info {st.info}", file=sys.stderr)
        sys.exit(2)


def cmd_baud(dev, a):
    exact = dev.set_baud(a.rate, calibrate=not a.no_calibrate)
    clk = dev.info().clk_hz
    host = clk / dev.measure_host_bit()
    print(f"device now at {exact:.0f} baud (div {dev.info().div_q8 / 256:.3f} clk/bit); host bridge measured "
          f"at {host:.0f} baud; use --baud {a.rate} for later commands")


def bl616_shell(port: str, lines: list[str], settle: float = 0.5) -> str:
    """Talk to the BL616 debugger's own shell: Ctrl-X and Ctrl-C as separate writes leave the UART bridge
    (Sipeed: Tang Nano 20K unbox guide).  Measured: `choose uart` does NOT bring the FPGA -> PC direction back,
    so every use of the shell must end with `reboot`.  Returns everything the shell printed."""
    import serial
    s = serial.Serial(port, 115200, timeout=0.2)
    out = bytearray()
    try:
        for chunk in [b"\x18", b"\x03", b"\r"] + [l.encode() + b"\r" for l in lines]:
            s.write(chunk)
            time.sleep(settle)
            try:
                out += s.read(s.in_waiting or 1)
            except Exception:              # the port disappears on `reboot`
                break
    finally:
        try:
            s.close()
        except Exception:
            pass
    return re.sub(r"\x1b\[[0-9;]*m", "", out.decode("latin-1"))


def cmd_bridge(a):
    port = a.port if a.port and a.port not in ("auto", "fake") else find_port()
    text = bl616_shell(port, (["uart_info"] if a.action == "info" else []) + ["reboot"])
    time.sleep(6)                          # USB re-enumeration
    print(text.replace("\r", ""))


def bench_one(dev, size: int, window: int, rng: random.Random) -> dict:
    words = [rng.getrandbits(64) for _ in range(size // 8)]
    sp = SPACES["TEST"]
    t0 = time.perf_counter()
    dev.write(sp, 0, 0, words, window=window)
    t1 = time.perf_counter()
    back = dev.read(sp, 0, 0, len(words), window=window)
    t2 = time.perf_counter()
    bad = sum(1 for x, y in zip(words, back) if x != y) + abs(len(words) - len(back))
    t3 = time.perf_counter()
    n = 0
    while time.perf_counter() - t3 < 0.5:
        dev.ping()
        n += 1
    rtt = (time.perf_counter() - t3) / n
    return {"write_s": t1 - t0, "read_s": t2 - t1, "bad": bad, "rtt_ms": rtt * 1000}


def cmd_bench(dev, a):
    rng = random.Random(a.seed)
    inf = dev.info()
    if SPACES["TEST"] not in inf.space_depth:
        raise SystemExit("bench needs the board_test design (TEST space)")
    size = min(a.size, inf.space_depth[SPACES["TEST"]] * 8)
    start_baud = dev.link.baudrate
    rows = []
    for baud in [int(x) for x in a.bauds.split(",")]:
        try:
            if baud != dev.link.baudrate:
                exact = dev.set_baud(baud, calibrate=not a.no_calibrate)
            else:
                exact = dev.info().baud
        except ProtocolError as e:
            print(f"{baud:>9}: SET_BAUD failed: {e}")
            rows.append((baud, None))
            continue
        host = inf.clk_hz / dev.measure_host_bit()
        print(f"{baud:>9}: FPGA div {dev.info().div_q8 / 256:.3f} clk/bit = {exact:.0f} baud, "
              f"bridge measured {host:.0f} baud ({(host / baud - 1) * 100:+.2f} %)")
        dev.reset(clear_counters=True)
        for window in [int(x) for x in a.windows.split(",")]:
            for rep in range(a.repeat):
                r = bench_one(dev, size, window, rng)
                st = dev.status()
                wr = size / r["write_s"] / 1024
                rd = size / r["read_s"] / 1024
                wire = baud / 10 / 1024
                print(f"{baud:>9} (exact {exact:.0f}) win={window:<5} {size} B: write {wr:7.1f} KiB/s, "
                      f"read {rd:7.1f} KiB/s (wire max {wire:.1f}), mismatches {r['bad']}, "
                      f"ping rtt {r['rtt_ms']:.2f} ms, crc_err {st.crc_err} frame_err {st.frame_err} "
                      f"overrun {st.overrun} timeout {st.timeout} retries {dev.link.stats['retries']}")
                rows.append((baud, r))
    if dev.link.baudrate != start_baud and not a.stay:
        dev.set_baud(start_baud)
    bad = any(r is None or r["bad"] for _, r in rows)
    sys.exit(1 if bad else 0)


def main(argv=None):
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--port", default=os.environ.get("MNHOST_PORT", "auto"))
    ap.add_argument("--baud", type=int, default=int(os.environ.get("MNHOST_BAUD", "1000000")))
    ap.add_argument("-v", "--verbose", action="store_true")
    sub = ap.add_subparsers(dest="cmd", required=True)

    p = sub.add_parser("ping"); p.add_argument("--size", type=int, default=0)
    p.add_argument("--count", type=int, default=1); p.set_defaults(fn=cmd_ping)
    sub.add_parser("info").set_defaults(fn=cmd_info)
    sub.add_parser("status").set_defaults(fn=cmd_status)
    p = sub.add_parser("reset"); p.add_argument("--clear", action="store_true", help="also clear link counters")
    p.set_defaults(fn=cmd_reset)

    p = sub.add_parser("write", help="write long words: SPACE LOC ADDR HEX...")
    p.add_argument("space"); p.add_argument("loc"); p.add_argument("addr"); p.add_argument("values", nargs="*")
    p.add_argument("--file", help="binary file (little-endian long words)")
    p.add_argument("--mask", default="ff"); p.add_argument("--window", type=int, default=0)
    p.set_defaults(fn=cmd_write)

    p = sub.add_parser("read", help="read long words: SPACE LOC ADDR N (prints ndmp lines)")
    p.add_argument("space"); p.add_argument("loc"); p.add_argument("addr"); p.add_argument("n", type=int)
    p.add_argument("--window", type=int, default=0); p.set_defaults(fn=cmd_read)

    p = sub.add_parser("run", help="run an .asm (flat, no packer) or a raw RUN")
    p.add_argument("asm", nargs="?")
    p.add_argument("-o", "--output", help="ndmp output file (default stdout)")
    p.add_argument("--start", type=int, default=0); p.add_argument("--count", type=int)
    p.add_argument("--no-wait", action="store_true")
    p.add_argument("--topo", help="override implemented topology n,c,b,m,p (default from INFO)")
    p.add_argument("--map-test", action="store_true",
                   help="board_test smoke test: map every space into the TEST memory")
    p.add_argument("--run-timeout", type=float, default=30.0)
    p.set_defaults(fn=cmd_run)

    p = sub.add_parser("baud", help="switch the device baud rate (until reset)")
    p.add_argument("rate", type=int)
    p.add_argument("--no-calibrate", action="store_true", help="keep the nominal divider")
    p.set_defaults(fn=cmd_baud)

    p = sub.add_parser("bench", help="64 KiB write/read check and speed per baud rate (board_test)")
    p.add_argument("--bauds", default="1000000,2000000,3000000")
    p.add_argument("--size", type=int, default=65536)
    p.add_argument("--windows", default="0,4096",
                   help="pipelining windows to test (response bytes in flight; 0 = stop-and-wait)")
    p.add_argument("--repeat", type=int, default=1)
    p.add_argument("--seed", type=int, default=1)
    p.add_argument("--stay", action="store_true", help="leave the device at the last baud rate")
    p.add_argument("--no-calibrate", action="store_true", help="use the nominal FPGA divider")
    p.set_defaults(fn=cmd_bench)

    p = sub.add_parser("bridge", help="BL616 debugger shell: reboot (recovers a hung UART bridge, like "
                                      "re-plugging USB) or info (uart_info, then reboot)")
    p.add_argument("action", choices=["info", "reboot"])
    p.set_defaults(fn=None)

    a = ap.parse_args(argv)
    if a.cmd == "bridge":
        cmd_bridge(a)
        return
    dev = connect(a)
    try:
        a.fn(dev, a)
    except (ProtocolError, DeviceError) as e:
        print(f"error: {e}", file=sys.stderr)
        sys.exit(1)


if __name__ == "__main__":
    sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
    main()
