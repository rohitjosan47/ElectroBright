#!/usr/bin/env python3
"""
ElectroBright firmware — conformance & stress suite for every fixture.

Talks to a fixture exactly like the Flutter app does and checks every reply
against the protocol contract (docs/protocol.md). The fixture's channel layout
is read from INFO / CAPS (LAYOUT=...), and every colour width, binary frame
and STATUS field position is derived from it, so the same suite covers the
RGBW, RGB, RGBCCT, CCT, W and future fixtures.

On a real fixture over Bluetooth:

    pip install bleak
    python3 fw_conformance.py                    # contract + short stress (~2 min)
    python3 fw_conformance.py --name RGB         # pick a fixture by BLE-name substring
    python3 fw_conformance.py --stress 600       # 10-minute 60 Hz binary stream
    python3 fw_conformance.py --cycles 100       # connect/disconnect endurance
    python3 fw_conformance.py --persist          # interactive power-cycle persistence check
    python3 fw_conformance.py --factory-reset    # also exercise FACTORY_RESET (wipes presets!)

Against the firmware simulator (no hardware; firmware/test/build/fwsim/fwsim):

    python3 fw_conformance.py --fwsim ../test/build/fwsim/fwsim --fixture rgb

The suite restores the fixture's colour / mode / brightness / sound when it
finishes and only uses preset slot 14, the last of 15 (deleted afterwards if
it was empty).
"""

import argparse
import asyncio
import re
import sys
import time

NUS_SERVICE = "6e400001-b5a3-f393-e0a9-e50e24dcca9e"
NUS_RX = "6e400002-b5a3-f393-e0a9-e50e24dcca9e"  # phone -> device
NUS_TX = "6e400003-b5a3-f393-e0a9-e50e24dcca9e"  # device -> phone
NAME_PREFIX = "ElectroBright_C3_"
PRESET_SLOTS = 15  # firmware: cfg::kNumPresets, announced as CAPS PRESETS=
TEST_SLOT = PRESET_SLOTS - 1

# Channel roles per layout, in wire order (firmware: fixture/ChannelLayout.h).
LAYOUTS = {
    "RGBW": ["R", "G", "B", "W"],
    "RGB": ["R", "G", "B"],
    "RGBCCT": ["R", "G", "B", "CW", "WW"],
    "CCT": ["CW", "WW"],
    "W": ["W"],
}
# Colour slot each role reads (firmware: core/Types.h): r, g, b, w (W or CW), ww.
SLOT = {"R": 0, "G": 1, "B": 2, "W": 3, "CW": 3, "WW": 4}


class Layout:
    """Wire widths and STATUS positions for one channel layout."""

    def __init__(self, name):
        if name not in LAYOUTS:
            raise ValueError(f"unknown layout {name}")
        self.name = name
        self.roles = LAYOUTS[name]
        self.n = len(self.roles)
        # The RGBW command exists only on layouts with colour LEDs and a W LED.
        self.has_w = "W" in self.roles and "R" in self.roles

    @property
    def status_fields(self):
        return 3 * self.n + 11

    def salt(self):
        return 0x55 if self.n == 4 else (0x55 ^ self.n)

    def frame(self, seq, colour, br):
        """[AA, seq, c1..cn, Br, cs]  with cs = xor(seq..Br) ^ salt."""
        assert len(colour) == self.n
        body = [seq & 0xFF, *colour, br]
        cs = self.salt()
        for b in body:
            cs ^= b
        return bytes([0xAA, *body, cs & 0xFF])

    def colour(self, *slots):
        """Wire values of a colour given in slot order (r, g, b, w, ww; missing = 0)."""
        v = list(slots) + [0] * (5 - len(slots))
        return [v[SLOT[role]] for role in self.roles]

    def parse_status(self, line):
        if not line or not line.startswith("STATUS:"):
            return None
        v = [int(x) for x in line[7:].split(",")]
        if len(v) != self.status_fields:
            return None
        n = self.n
        return {
            "colour": v[0:n], "br": v[n], "mode": v[n + 1], "speed": v[n + 2], "freq": v[n + 3],
            "cm": v[n + 4:n + 7], "sleep": v[n + 7], "timer": v[n + 8], "remaining": v[n + 9],
            "sound": v[n + 10], "polA": v[n + 11:2 * n + 11], "polB": v[2 * n + 11:3 * n + 11],
        }


class Results:
    def __init__(self):
        self.passed = 0
        self.failed = []

    def check(self, cond, name, detail=""):
        if cond:
            self.passed += 1
            print(f"  ok    {name}")
        else:
            self.failed.append(name)
            print(f"  FAIL  {name}  {detail}")
        return cond


# ----------------------------------------------------------------------------- transports
class BleTransport:
    def __init__(self, client):
        self.client = client

    async def start(self, on_notify):
        await self.client.start_notify(NUS_TX, lambda _h, data: on_notify(bytes(data)))

    async def write(self, data, response):
        await self.client.write_gatt_char(NUS_RX, data, response=response)


class FwsimTransport:
    """The real firmware core in fwsim (firmware/test/fwsim), in real time."""

    def __init__(self, path, fixture):
        self.path = path
        self.fixture = fixture
        self.proc = None
        self.lock = asyncio.Lock()
        self.on_notify = None
        self.ticker = None

    async def _request(self, line):
        async with self.lock:
            self.proc.stdin.write((line + "\n").encode())
            await self.proc.stdin.drain()
            while True:
                reply = (await self.proc.stdout.readline()).decode().rstrip("\n")
                if reply == ".":
                    return
                if reply == "":
                    raise RuntimeError("fwsim exited")
                if reply.startswith("N ") and self.on_notify:
                    self.on_notify(bytes.fromhex(reply[2:]))
                elif reply.startswith("!"):
                    raise RuntimeError(f"fwsim: {reply}")

    async def _tick(self):
        while True:  # virtual time follows the wall clock (timer tests wait for real)
            await asyncio.sleep(0.05)
            await self._request("ADV 50")

    async def start(self, on_notify):
        self.on_notify = on_notify
        self.proc = await asyncio.create_subprocess_exec(
            self.path, "--fixture", self.fixture, stdin=asyncio.subprocess.PIPE, stdout=asyncio.subprocess.PIPE)
        for line in ("HELLO", "CONNECT", "SUB 1", "MTU 247"):
            await self._request(line)
        self.ticker = asyncio.create_task(self._tick())

    async def write(self, data, response):
        await self._request("W " + data.hex().upper())

    async def close(self):
        if self.ticker:
            self.ticker.cancel()
        if self.proc:
            self.proc.stdin.write(b"QUIT\n")
            await self.proc.stdin.drain()
            await self.proc.wait()


class Fixture:
    """One session with '\\n' line reassembly (same as the app)."""

    def __init__(self, transport):
        self.transport = transport
        self.buf = ""
        self.lines = asyncio.Queue()
        self.layout = None
        self.modes = set(range(1, 14))  # CAPS MODES=<hex mask>; absent = all 13

    async def start(self):
        await self.transport.start(self._on_notify)

    def _on_notify(self, data):
        self.buf += data.decode("utf-8", errors="replace")
        while "\n" in self.buf:
            line, self.buf = self.buf.split("\n", 1)
            line = line.strip()
            if line:
                self.lines.put_nowait(line)

    async def identify(self):
        """Reads INFO / CAPS and selects the layout."""
        info = await self.cmd("INFO", "INFO:")
        caps = await self.cmd("CAPS", "CAPS:")
        m = re.match(r"^INFO:EB-[A-Z0-9]+-([A-Z]+)-V\d+$", info or "")
        layout = None
        if caps:
            fields = dict(f.split("=", 1) for f in caps[5:].split(",") if "=" in f)
            layout = fields.get("LAYOUT")
            if "MODES" in fields:
                mask = int(fields["MODES"], 16)
                self.modes = {m for m in range(1, 14) if mask & (1 << (m - 1))}
        if layout is None and m and m.group(1) == "RGBW":
            layout = "RGBW"  # firmware 3.4.0 predates LAYOUT
        self.layout = Layout(layout) if layout in LAYOUTS else None
        return info, caps

    def drain(self):
        while not self.lines.empty():
            self.lines.get_nowait()

    async def write(self, text, response=True):
        await self.transport.write(text.encode(), response)

    async def write_bytes(self, data, response=False):
        await self.transport.write(data, response)

    async def expect(self, prefix, timeout=2.0):
        """Next line starting with prefix (other lines are skipped)."""
        deadline = time.monotonic() + timeout
        while True:
            left = deadline - time.monotonic()
            if left <= 0:
                return None
            try:
                line = await asyncio.wait_for(self.lines.get(), left)
            except asyncio.TimeoutError:
                return None
            if line.startswith(prefix):
                return line

    async def cmd(self, text, prefix, timeout=2.0):
        self.drain()
        await self.write(text + "\n")
        return await self.expect(prefix, timeout)

    async def silent(self, text, window=0.4):
        """Sends a command that must produce no reply."""
        self.drain()
        await self.write(text + "\n")
        await asyncio.sleep(window)
        extra = []
        while not self.lines.empty():
            extra.append(self.lines.get_nowait())
        return extra

    async def status(self):
        return self.layout.parse_status(await self.cmd("STATUS", "STATUS:"))

    async def diag(self):
        line = await self.cmd("DIAG", "DIAG:")
        return dict(f.split("=", 1) for f in line[5:].split(",")) if line else {}


def csv(values):
    return ",".join(str(v) for v in values)


async def find_device(name_filter=None, timeout=10.0):
    from bleak import BleakScanner

    print(f"Scanning for '{NAME_PREFIX}*' ...")
    devices = await BleakScanner.discover(timeout=timeout, service_uuids=[NUS_SERVICE])
    for d in devices:
        if d.name and d.name.startswith(NAME_PREFIX) and (not name_filter or name_filter in d.name):
            print(f"Found {d.name} [{d.address}]")
            return d
    return None


# ----------------------------------------------------------------------------- suites
async def suite_handshake(fx, R, info, caps, expect_version):
    L = fx.layout
    print(f"\n[handshake — the app's connect sequence; layout {L.name}, {L.n} channels]")
    R.check(re.match(rf"^INFO:EB-C3-{L.name}-V\d+$", info or "") is not None, "INFO identifies model and layout", info)
    R.check(caps is not None and "PROTOCOL=1" in caps, "CAPS reports PROTOCOL=1", caps)
    R.check(caps is not None and f"LAYOUT={L.name}" in caps, f"CAPS reports LAYOUT={L.name}", caps)
    R.check(caps is not None and f"PRESETS={PRESET_SLOTS}" in caps.split(":", 1)[1].split(","),
            f"CAPS reports PRESETS={PRESET_SLOTS}", caps)
    st = await fx.cmd("STATUS", "STATUS:")
    R.check(st is not None and len(st[7:].split(",")) == L.status_fields, f"STATUS has {L.status_fields} fields", st)
    ms = await fx.cmd("MODE_SETTINGS", "MODE_SETTINGS:")
    R.check(ms is not None and len(ms[14:].split(";")) == 13, "MODE_SETTINGS has 13 pairs", ms)
    pl = await fx.cmd("PRESET_LIST", "PRESETS:")
    R.check(pl is not None, "PRESET_LIST answers PRESETS:", pl)
    v = await fx.cmd("VERSION", "VERSION:")
    if expect_version:
        R.check(v == f"VERSION:{expect_version}", f"VERSION:{expect_version}", v)
    else:
        R.check(re.match(r"^VERSION:3\.\d+\.\d+", v or "") is not None, "VERSION is 3.x", v)


async def suite_commands(fx, R):
    L = fx.layout
    print("\n[commands]")
    c = L.colour(10, 20, 30, 40, 50)
    R.check(await fx.silent(f"COLOR:{csv(c)}") == [], "COLOR is silent")
    R.check(await fx.silent("BRIGHTNESS:200") == [], "BRIGHTNESS is silent")
    s = await fx.status()
    R.check(s and s["colour"] == c and s["br"] == 200, "COLOR/BRIGHTNESS applied", s)
    if L.has_w:
        R.check(await fx.silent("RGBW:11,21,31,41") == [], "RGBW is silent")
        s = await fx.status()
        R.check(s and s["colour"] == [11, 21, 31, 41], "RGBW applied", s)

    R.check(await fx.cmd("MODE:11", "OK") == "OK", "MODE replies OK")
    await fx.silent("SPEED:8")
    await fx.silent("FREQUENCY:3")
    s = await fx.status()
    R.check(s and s["mode"] == 11 and s["speed"] == 8 and s["freq"] == 3, "SPEED/FREQUENCY target the active mode", s)

    pa, pb = L.colour(1, 2, 3, 4, 5), L.colour(6, 7, 8, 9, 10)
    for cmd in ["FIREWORK_COLOR_MODE:1", "CLUB_COLOR_MODE:1", "POLICE_COLOR_MODE:0", f"POLICE_COLOR_A:{csv(pa)}",
                f"POLICE_COLOR_B:{csv(pb)}", "MODE_SPEED:4,9", "MODE_FREQUENCY:4,2", "PING"]:
        R.check(await fx.cmd(cmd, "OK") == "OK", f"{cmd.split(':')[0]} replies OK")
    s = await fx.status()
    R.check(s and s["cm"] == [1, 1, 0] and s["polA"] == pa and s["polB"] == pb,
            "colour modes + police colours in STATUS", s)

    expected_caps = {1: "NONE", 2: "FREQUENCY", 3: "SPEED,FREQUENCY", 4: "SPEED,FREQUENCY,COLOR_MODE",
                     6: "SPEED,FREQUENCY", 8: "SPEED,FREQUENCY", 9: "SPEED,FREQUENCY,COLOR_MODE", 10: "FREQUENCY",
                     12: "SPEED,FREQUENCY,COLOR_MODE", 13: "SPEED,FREQUENCY"}
    for m, cap in expected_caps.items():
        if m not in fx.modes:
            continue
        line = await fx.cmd(f"MODE_CAPABILITIES:{m}", "CAPABILITIES:")
        R.check(line == f"CAPABILITIES:{cap}", f"MODE_CAPABILITIES:{m}", line)
    for m in sorted(set(range(1, 14)) - fx.modes):
        for cmd, err in ((f"MODE:{m}", "ERROR:MODE_INVALID"), (f"MODE_SPEED:{m},3", "ERROR:MODE_SPEED_INVALID"),
                         (f"MODE_CAPABILITIES:{m}", "ERROR:MODE_INVALID")):
            line = await fx.cmd(cmd, "ERROR:")
            R.check(line == err, f"unsupported mode: {cmd} -> {err}", line)

    # Tolerance: lower case, spaces, CRLF.
    R.check(await fx.cmd(" status \r", "STATUS:") is not None, "case/whitespace/CR tolerant")


async def suite_errors(fx, R):
    L = fx.layout
    print("\n[error handling]")
    cases = {"MODE:0": "ERROR:MODE_INVALID", "MODE:14": "ERROR:MODE_INVALID",
             "SPEED:11": "ERROR:SPEED_OUT_OF_BOUNDS", "FREQUENCY:0": "ERROR:FREQUENCY_INVALID",
             f"COLOR:{csv([1] * (L.n - 1))}": "ERROR:FORMAT",
             f"COLOR:{csv([1] * (L.n + 1))}": "ERROR:FORMAT",
             f"COLOR:{csv([256] + [0] * (L.n - 1))}": "ERROR:FORMAT",
             f"POLICE_COLOR_A:{csv([1] * (L.n + 1))}": "ERROR:FORMAT",
             "BRIGHTNESS:x": "ERROR:BRIGHTNESS_INVALID", "PRESET_LOAD:15": "ERROR:PRESET_ID",
             "TIMER:86401": "ERROR:FORMAT", "NOPE": "ERROR:UNKNOWN_CMD"}
    if not L.has_w:
        cases["RGBW:1,2,3,4"] = "ERROR:UNKNOWN_CMD"
    for c, err in cases.items():
        line = await fx.cmd(c, "ERROR:")
        R.check(line == err, f"{c} -> {err}", line)
    # An over-long line is dropped silently (never executed truncated).
    R.check(await fx.silent("COLOR:" + "1," * 80 + "1") == [], "over-long line ignored")
    # Fragmented command across writes.
    fx.drain()
    await fx.write("STA")
    await fx.write("TUS\n")
    R.check(await fx.expect("STATUS:") is not None, "command split across writes")


async def suite_binary(fx, R):
    L = fx.layout
    print("\n[binary colour frames]")
    d0 = await fx.diag()
    c = L.colour(40, 80, 120, 160, 200)
    await fx.write_bytes(L.frame(3, c, 150), response=True)
    await asyncio.sleep(0.2)
    s = await fx.status()
    R.check(s and s["colour"] == c and s["br"] == 150, f"{L.n + 4}-byte frame applied", s)
    # A frame for another layout (or a corrupted one) is rejected, never applied.
    for other in LAYOUTS:
        if other == L.name:
            continue
        o = Layout(other)
        await fx.write_bytes(o.frame(4, o.colour(1, 2, 3, 4, 5), 9), response=True)
    bad = bytearray(L.frame(5, L.colour(9, 9, 9, 9, 9), 9))
    bad[-1] ^= 0xFF
    await fx.write_bytes(bytes(bad), response=True)
    await asyncio.sleep(0.2)
    s = await fx.status()
    d1 = await fx.diag()
    rejected = int(d1.get("binbad", 0)) - int(d0.get("binbad", 0))
    R.check(s and s["colour"] == c, "foreign / corrupted frames not applied", s)
    R.check(rejected == len(LAYOUTS), f"{len(LAYOUTS)} bad frames counted (binbad)", d1.get("binbad"))
    R.check(await fx.cmd("PING", "OK") == "OK", "text still works after bad frames")


async def suite_presets(fx, R):
    L = fx.layout
    print("\n[presets]")
    before = await fx.cmd("PRESET_LIST", "PRESETS:")
    was_used = before is not None and f"{TEST_SLOT}," in before
    c = L.colour(1, 2, 3, 4, 5)
    await fx.silent(f"COLOR:{csv(c)}")
    await fx.cmd("MODE:9", "OK")
    R.check(await fx.cmd(f"PRESET_SAVE:{TEST_SLOT}", "OK") == "OK", "PRESET_SAVE")
    pl = await fx.cmd("PRESET_LIST", "PRESETS:")
    R.check(pl is not None and f"{TEST_SLOT}," in pl, "slot listed after save", pl)
    await fx.silent(f"COLOR:{csv(L.colour(200, 200, 200, 0, 200))}")
    await fx.cmd("MODE:1", "OK")
    s = L.parse_status(await fx.cmd(f"PRESET_LOAD:{TEST_SLOT}", "STATUS:"))
    R.check(s and s["colour"] == c and s["mode"] == 9, "PRESET_LOAD answers with the preset's STATUS", s)
    if not was_used:
        R.check(await fx.cmd(f"PRESET_DELETE:{TEST_SLOT}", "OK") == "OK", "PRESET_DELETE")
        line = await fx.cmd(f"PRESET_LOAD:{TEST_SLOT}", "ERROR:")
        R.check(line == f"ERROR:PRESET_EMPTY:{TEST_SLOT}", "empty slot -> ERROR:PRESET_EMPTY:<id>", line)


async def suite_sleep_timer(fx, R):
    L = fx.layout
    print("\n[sleep / wake / timer]")
    R.check(await fx.cmd("SLEEP", "OK") == "OK", "SLEEP")
    s = await fx.status()
    R.check(s and s["sleep"] == 1, "STATUS sleeping=1", s)
    red = L.colour(255, 0, 0, 0, 255)  # red, or warm white on a white-only light
    await fx.write_bytes(L.frame(1, red, 255), response=True)
    await asyncio.sleep(0.2)
    s = await fx.status()
    R.check(s and s["sleep"] == 1 and s["colour"] == red, "binary colour while asleep updates target, stays asleep", s)
    R.check(await fx.cmd("WAKE", "OK") == "OK", "WAKE")
    s = await fx.status()
    R.check(s and s["sleep"] == 0, "STATUS sleeping=0", s)

    R.check(await fx.cmd("TIMER:3", "OK") == "OK", "TIMER:3")
    s = await fx.status()
    R.check(s and s["timer"] == 1 and 1 <= s["remaining"] <= 3, "timer active with remaining seconds", s)
    fx.drain()
    pushed = L.parse_status(await fx.expect("STATUS:", timeout=5.0))
    R.check(pushed and pushed["sleep"] == 1 and pushed["timer"] == 0, "timer expiry pushes unsolicited STATUS (asleep)",
            pushed)
    await fx.cmd("WAKE", "OK")
    await fx.cmd("TIMER:600", "OK")
    await fx.cmd("SLEEP", "OK")
    s = await fx.status()
    R.check(s and s["timer"] == 0, "SLEEP cancels the timer", s)
    await fx.cmd("WAKE", "OK")


async def suite_identify(fx, R, caps):
    print("\n[identify]")
    R.check(caps is not None and "IDENTIFY=1" in caps.split(":", 1)[1].split(","), "CAPS reports IDENTIFY=1", caps)
    before = await fx.status()
    R.check(await fx.cmd("IDENTIFY", "OK") == "OK", "IDENTIFY replies OK")
    R.check(await fx.cmd("IDENTIFY", "OK") == "OK", "IDENTIFY again (restarts) replies OK")
    await asyncio.sleep(0.8)  # the flashes are over
    R.check(await fx.status() == before, "IDENTIFY changes no state", before)
    await fx.cmd("SLEEP", "OK")
    R.check(await fx.cmd("IDENTIFY", "OK") == "OK", "IDENTIFY while asleep replies OK")
    s = await fx.status()
    R.check(s and s["sleep"] == 1, "IDENTIFY does not wake the light", s)
    await fx.cmd("WAKE", "OK")
    line = await fx.cmd("IDENTIFY:1", "ERROR:")
    R.check(line == "ERROR:FORMAT", "IDENTIFY takes no arguments -> ERROR:FORMAT", line)


async def suite_sound(fx, R, original_sound):
    print("\n[sound]")
    R.check(await fx.cmd("SOUND_OFF", "OK") == "OK", "SOUND_OFF")
    s = await fx.status()
    R.check(s and s["sound"] == 0, "STATUS sound=0", s)
    R.check(await fx.cmd("SOUND_ON", "OK") == "OK", "SOUND_ON")
    s = await fx.status()
    R.check(s and s["sound"] == 1, "STATUS sound=1", s)
    await fx.cmd("SOUND_ON" if original_sound else "SOUND_OFF", "OK")


async def suite_stress(fx, R, seconds):
    L = fx.layout
    print(f"\n[stress — 60 Hz binary stream for {seconds}s]")
    diag0 = await fx.diag()
    seq = 0
    t_end = time.monotonic() + seconds
    sent = 0
    last = L.colour(0, 0, 0, 0, 0)
    while time.monotonic() < t_end:
        hue = (sent * 3) % 765
        r, g, b = (hue, 255 - hue, 0) if hue < 256 else ((0, 510 - hue, hue - 255) if hue < 510 else (hue - 510, 0, 765 - hue))
        r, g, b = max(0, min(255, r)), max(0, min(255, g)), max(0, min(255, b))
        last = L.colour(r, g, b, g, r)  # white slots too, so white-only lights stream as well
        await fx.write_bytes(L.frame(seq, last, 200), response=False)
        seq = (seq + 1) & 0xFF
        sent += 1
        await asyncio.sleep(1 / 60)
    await fx.write_bytes(L.frame(seq, last, 200), response=True)  # terminal value, like the app
    await asyncio.sleep(0.3)
    s = await fx.status()
    R.check(s and s["colour"] == last and s["br"] == 200, f"final colour applied after {sent} packets", s)
    diag = await fx.diag()
    bad = int(diag.get("binbad", -1)) - int(diag0.get("binbad", 0))
    R.check(bad == 0, "no corrupted binary frames during the stream", f"binbad +{bad}")
    print(f"      DIAG before: {diag0}\n      DIAG after:  {diag}")


async def run_suites(fx, R, args):
    info, caps = await fx.identify()
    if fx.layout is None:
        print(f"Unknown fixture layout (INFO {info!r}, CAPS {caps!r}).")
        return None
    original = await fx.status()
    if original is None:
        print("Fixture does not answer a valid STATUS.")
        return None

    await suite_handshake(fx, R, info, caps, args.expect_version)
    await suite_commands(fx, R)
    await suite_errors(fx, R)
    await suite_binary(fx, R)
    await suite_presets(fx, R)
    await suite_sleep_timer(fx, R)
    await suite_identify(fx, R, caps)
    await suite_sound(fx, R, original["sound"] == 1)
    if args.stress > 0:
        await suite_stress(fx, R, args.stress)
    if args.factory_reset:
        print("\n[factory reset]")
        R.check(await fx.cmd("FACTORY_RESET", "OK") == "OK", "FACTORY_RESET replies OK (no reboot)")
        R.check(await fx.cmd("PRESET_LIST", "PRESETS:") == "PRESETS:", "no presets after reset")

    # Restore the user's look.
    await fx.silent(f"COLOR:{csv(original['colour'])}")
    await fx.silent(f"BRIGHTNESS:{original['br']}")
    await fx.cmd(f"MODE:{original['mode']}", "OK")
    if original["sleep"] == 1:
        await fx.cmd("SLEEP", "OK")
    return original


async def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--stress", type=int, default=30, help="seconds of 60 Hz binary streaming (0 = skip)")
    ap.add_argument("--cycles", type=int, default=0, help="connect/disconnect cycles (Bluetooth only)")
    ap.add_argument("--persist", action="store_true", help="interactive power-cycle persistence check (Bluetooth only)")
    ap.add_argument("--factory-reset", action="store_true", help="also test FACTORY_RESET (erases presets)")
    ap.add_argument("--name", help="only fixtures whose BLE name contains this text")
    ap.add_argument("--expect-version", help="exact firmware version expected (default: any 3.x)")
    ap.add_argument("--fwsim", help="run against the firmware simulator binary instead of Bluetooth")
    ap.add_argument("--fixture", default="rgbw", help="fwsim fixture (rgbw, rgb, rgbcct, cct, w)")
    args = ap.parse_args()

    R = Results()
    if args.fwsim:
        transport = FwsimTransport(args.fwsim, args.fixture)
        fx = Fixture(transport)
        await fx.start()
        try:
            if await run_suites(fx, R, args) is None:
                return 2
        finally:
            await transport.close()
    else:
        try:
            from bleak import BleakClient
        except ImportError:
            print("ERROR: install bleak first:  pip install bleak")
            return 2
        device = await find_device(args.name)
        if device is None:
            print("No ElectroBright v3 fixture found.")
            return 2
        async with BleakClient(device) as client:
            fx = Fixture(BleTransport(client))
            await fx.start()
            await asyncio.sleep(0.3)
            if await run_suites(fx, R, args) is None:
                return 2
            layout = fx.layout

        if args.cycles:
            print(f"\n[{args.cycles} connect/disconnect cycles]")
            ok = 0
            for i in range(args.cycles):
                try:
                    async with BleakClient(device) as client:
                        fx = Fixture(BleTransport(client))
                        fx.layout = layout
                        await fx.start()
                        await asyncio.sleep(0.3)
                        ok += (await fx.status()) is not None
                except Exception as exc:  # noqa: BLE001 — report and continue
                    print(f"      cycle {i}: {exc}")
            R.check(ok == args.cycles, f"{ok}/{args.cycles} sessions answered STATUS")

        if args.persist:
            print("\n[persistence]")
            c = layout.colour(12, 34, 56, 78, 90)
            async with BleakClient(device) as client:
                fx = Fixture(BleTransport(client))
                fx.layout = layout
                await fx.start()
                await fx.silent(f"COLOR:{csv(c)}")
                await fx.cmd("MODE:13", "OK")
                print("      waiting 4 s for the debounced save ...")
                await asyncio.sleep(4)
            input("      Power-cycle the fixture now, then press Enter ... ")
            device = await find_device(args.name, 20)
            async with BleakClient(device) as client:
                fx = Fixture(BleTransport(client))
                fx.layout = layout
                await fx.start()
                s = await fx.status()
                R.check(s and s["colour"] == c and s["mode"] == 13, "state survives power cycle", s)

    print(f"\n{R.passed} passed, {len(R.failed)} failed")
    for f in R.failed:
        print(f"  - {f}")
    return 0 if not R.failed else 1


if __name__ == "__main__":
    sys.exit(asyncio.run(main()))
