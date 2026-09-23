#!/usr/bin/env python3
"""
ElectroBright firmware — on-device conformance & stress suite.

Talks to a flashed fixture over BLE exactly like the Flutter app does and
checks every reply against the protocol contract.

    pip install bleak
    python3 fw_conformance.py                    # contract + short stress (~2 min)
    python3 fw_conformance.py --stress 600       # 10-minute 60 Hz binary stream
    python3 fw_conformance.py --cycles 100       # connect/disconnect endurance
    python3 fw_conformance.py --persist          # interactive power-cycle persistence check
    python3 fw_conformance.py --factory-reset    # also exercise FACTORY_RESET (wipes presets!)

The suite restores the fixture's colour / mode / brightness / sound when it
finishes and only uses preset slot 24 (deleted afterwards if it was empty).
"""

import argparse
import asyncio
import sys
import time

try:
    from bleak import BleakClient, BleakScanner
except ImportError:
    print("ERROR: install bleak first:  pip install bleak")
    sys.exit(2)

NUS_SERVICE = "6e400001-b5a3-f393-e0a9-e50e24dcca9e"
NUS_RX = "6e400002-b5a3-f393-e0a9-e50e24dcca9e"  # phone -> device
NUS_TX = "6e400003-b5a3-f393-e0a9-e50e24dcca9e"  # device -> phone
NAME_PREFIX = "ElectroBright_C3_"
TEST_SLOT = 24


def binary_frame(seq, r, g, b, w, br):
    cs = (seq ^ r ^ g ^ b ^ w ^ br ^ 0x55) & 0xFF
    return bytes([0xAA, seq & 0xFF, r, g, b, w, br, cs])


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


class Fixture:
    """BLE session with '\\n' line reassembly (same as the app)."""

    def __init__(self, client):
        self.client = client
        self.buf = ""
        self.lines = asyncio.Queue()

    async def start(self):
        await self.client.start_notify(NUS_TX, self._on_notify)

    def _on_notify(self, _handle, data: bytearray):
        self.buf += data.decode("utf-8", errors="replace")
        while "\n" in self.buf:
            line, self.buf = self.buf.split("\n", 1)
            line = line.strip()
            if line:
                self.lines.put_nowait(line)

    def drain(self):
        while not self.lines.empty():
            self.lines.get_nowait()

    async def write(self, text, response=True):
        await self.client.write_gatt_char(NUS_RX, text.encode(), response=response)

    async def write_bytes(self, data, response=False):
        await self.client.write_gatt_char(NUS_RX, data, response=response)

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
        line = await self.cmd("STATUS", "STATUS:")
        return [int(x) for x in line[7:].split(",")] if line else None


async def find_device(timeout=10.0):
    print(f"Scanning for '{NAME_PREFIX}*' ...")
    devices = await BleakScanner.discover(timeout=timeout, service_uuids=[NUS_SERVICE])
    for d in devices:
        if d.name and d.name.startswith(NAME_PREFIX):
            print(f"Found {d.name} [{d.address}]")
            return d
    return None


# ----------------------------------------------------------------------------- suites
async def suite_handshake(fx, R):
    print("\n[handshake — the app's connect sequence]")
    st = await fx.cmd("STATUS", "STATUS:")
    R.check(st is not None and len(st[7:].split(",")) == 23, "STATUS has 23 fields", st)
    ms = await fx.cmd("MODE_SETTINGS", "MODE_SETTINGS:")
    R.check(ms is not None and len(ms[14:].split(";")) == 13, "MODE_SETTINGS has 13 pairs", ms)
    pl = await fx.cmd("PRESET_LIST", "PRESETS:")
    R.check(pl is not None, "PRESET_LIST answers PRESETS:", pl)
    v = await fx.cmd("VERSION", "VERSION:")
    R.check(v == "VERSION:3.4.0", "VERSION:3.4.0", v)
    caps = await fx.cmd("CAPS", "CAPS:")
    R.check(caps is not None and "PROTOCOL=1" in caps, "CAPS reports PROTOCOL=1", caps)
    info = await fx.cmd("INFO", "INFO:")
    R.check(info == "INFO:EB-C3-RGBW-V1", "INFO identifies the model", info)


async def suite_commands(fx, R):
    print("\n[commands]")
    R.check(await fx.silent("RGBW:10,20,30,40") == [], "RGBW is silent")
    R.check(await fx.silent("BRIGHTNESS:200") == [], "BRIGHTNESS is silent")
    s = await fx.status()
    R.check(s and s[0:5] == [10, 20, 30, 40, 200], "RGBW/BRIGHTNESS applied", s)

    R.check(await fx.cmd("MODE:11", "OK") == "OK", "MODE replies OK")
    await fx.silent("SPEED:8")
    await fx.silent("FREQUENCY:3")
    s = await fx.status()
    R.check(s and s[5] == 11 and s[6] == 8 and s[7] == 3, "SPEED/FREQUENCY target the active mode", s)

    for c in ["FIREWORK_COLOR_MODE:1", "CLUB_COLOR_MODE:1", "POLICE_COLOR_MODE:0",
              "POLICE_COLOR_A:1,2,3,4", "POLICE_COLOR_B:5,6,7,8", "MODE_SPEED:4,9", "MODE_FREQUENCY:4,2", "PING"]:
        R.check(await fx.cmd(c, "OK") == "OK", f"{c.split(':')[0]} replies OK")
    s = await fx.status()
    R.check(s and s[8:11] == [1, 1, 0] and s[15:23] == [1, 2, 3, 4, 5, 6, 7, 8],
            "colour modes + police colours in STATUS", s)

    expected_caps = {1: "NONE", 2: "FREQUENCY", 3: "SPEED,FREQUENCY", 4: "SPEED,FREQUENCY,COLOR_MODE",
                     6: "SPEED,FREQUENCY", 8: "SPEED,FREQUENCY", 9: "SPEED,FREQUENCY,COLOR_MODE", 10: "FREQUENCY",
                     12: "SPEED,FREQUENCY,COLOR_MODE", 13: "SPEED,FREQUENCY"}
    for m, cap in expected_caps.items():
        line = await fx.cmd(f"MODE_CAPABILITIES:{m}", "CAPABILITIES:")
        R.check(line == f"CAPABILITIES:{cap}", f"MODE_CAPABILITIES:{m}", line)

    # Tolerance: lower case, spaces, CRLF.
    R.check(await fx.cmd(" status \r", "STATUS:") is not None, "case/whitespace/CR tolerant")


async def suite_errors(fx, R):
    print("\n[error handling]")
    cases = {"MODE:0": "ERROR:MODE_INVALID", "MODE:14": "ERROR:MODE_INVALID",
             "SPEED:11": "ERROR:SPEED_OUT_OF_BOUNDS", "FREQUENCY:0": "ERROR:FREQUENCY_INVALID",
             "RGBW:1,2,3": "ERROR:FORMAT", "RGBW:256,0,0,0": "ERROR:FORMAT",
             "BRIGHTNESS:x": "ERROR:BRIGHTNESS_INVALID", "PRESET_LOAD:25": "ERROR:PRESET_ID",
             "TIMER:86401": "ERROR:FORMAT", "NOPE": "ERROR:UNKNOWN_CMD"}
    for c, err in cases.items():
        line = await fx.cmd(c, "ERROR:")
        R.check(line == err, f"{c} -> {err}", line)
    # An over-long line is dropped silently (never executed truncated).
    R.check(await fx.silent("RGBW:" + "1," * 80 + "1") == [], "over-long line ignored")
    # Fragmented command across writes.
    fx.drain()
    await fx.write("STA")
    await fx.write("TUS\n")
    R.check(await fx.expect("STATUS:") is not None, "command split across writes")


async def suite_presets(fx, R):
    print("\n[presets]")
    before = await fx.cmd("PRESET_LIST", "PRESETS:")
    was_used = before is not None and f"{TEST_SLOT}," in before
    await fx.silent("RGBW:1,2,3,4")
    await fx.cmd("MODE:9", "OK")
    R.check(await fx.cmd(f"PRESET_SAVE:{TEST_SLOT}", "OK") == "OK", "PRESET_SAVE")
    pl = await fx.cmd("PRESET_LIST", "PRESETS:")
    R.check(pl is not None and f"{TEST_SLOT}," in pl, "slot listed after save", pl)
    await fx.silent("RGBW:200,200,200,0")
    await fx.cmd("MODE:1", "OK")
    line = await fx.cmd(f"PRESET_LOAD:{TEST_SLOT}", "STATUS:")
    s = [int(x) for x in line[7:].split(",")] if line else None
    R.check(s and s[0:4] == [1, 2, 3, 4] and s[5] == 9, "PRESET_LOAD answers with the preset's STATUS", line)
    if not was_used:
        R.check(await fx.cmd(f"PRESET_DELETE:{TEST_SLOT}", "OK") == "OK", "PRESET_DELETE")
        line = await fx.cmd(f"PRESET_LOAD:{TEST_SLOT}", "ERROR:")
        R.check(line == f"ERROR:PRESET_EMPTY:{TEST_SLOT}", "empty slot -> ERROR:PRESET_EMPTY:<id>", line)


async def suite_sleep_timer(fx, R):
    print("\n[sleep / wake / timer]")
    R.check(await fx.cmd("SLEEP", "OK") == "OK", "SLEEP")
    s = await fx.status()
    R.check(s and s[11] == 1, "STATUS sleeping=1", s)
    await fx.write_bytes(binary_frame(1, 255, 0, 0, 0, 255), response=True)
    await asyncio.sleep(0.2)
    s = await fx.status()
    R.check(s and s[11] == 1 and s[0] == 255, "binary colour while asleep updates target, stays asleep", s)
    R.check(await fx.cmd("WAKE", "OK") == "OK", "WAKE")
    s = await fx.status()
    R.check(s and s[11] == 0, "STATUS sleeping=0", s)

    R.check(await fx.cmd("TIMER:3", "OK") == "OK", "TIMER:3")
    s = await fx.status()
    R.check(s and s[12] == 1 and 1 <= s[13] <= 3, "timer active with remaining seconds", s)
    fx.drain()
    pushed = await fx.expect("STATUS:", timeout=5.0)
    vals = [int(x) for x in pushed[7:].split(",")] if pushed else None
    R.check(vals and vals[11] == 1 and vals[12] == 0, "timer expiry pushes unsolicited STATUS (asleep)", pushed)
    await fx.cmd("WAKE", "OK")
    await fx.cmd("TIMER:600", "OK")
    await fx.cmd("SLEEP", "OK")
    s = await fx.status()
    R.check(s and s[12] == 0, "SLEEP cancels the timer", s)
    await fx.cmd("WAKE", "OK")


async def suite_sound(fx, R, original_sound):
    print("\n[sound]")
    R.check(await fx.cmd("SOUND_OFF", "OK") == "OK", "SOUND_OFF")
    s = await fx.status()
    R.check(s and s[14] == 0, "STATUS sound=0", s)
    R.check(await fx.cmd("SOUND_ON", "OK") == "OK", "SOUND_ON")
    s = await fx.status()
    R.check(s and s[14] == 1, "STATUS sound=1", s)
    await fx.cmd("SOUND_ON" if original_sound else "SOUND_OFF", "OK")


async def suite_stress(fx, R, seconds):
    print(f"\n[stress — 60 Hz binary stream for {seconds}s]")
    diag0 = await fx.cmd("DIAG", "DIAG:")
    seq = 0
    t_end = time.monotonic() + seconds
    sent = 0
    last = (0, 0, 0, 0, 0)
    while time.monotonic() < t_end:
        hue = (sent * 3) % 765
        r, g, b = (hue, 255 - hue, 0) if hue < 256 else ((0, 510 - hue, hue - 255) if hue < 510 else (hue - 510, 0, 765 - hue))
        r, g, b = max(0, min(255, r)), max(0, min(255, g)), max(0, min(255, b))
        last = (r, g, b, 0, 200)
        await fx.write_bytes(binary_frame(seq, *last), response=False)
        seq = (seq + 1) & 0xFF
        sent += 1
        await asyncio.sleep(1 / 60)
    await fx.write_bytes(binary_frame(seq, *last), response=True)  # terminal value, like the app
    await asyncio.sleep(0.3)
    s = await fx.status()
    R.check(s and tuple(s[0:4]) == last[0:4] and s[4] == 200, f"final colour applied after {sent} packets", s)
    diag = await fx.cmd("DIAG", "DIAG:")
    R.check(diag is not None and "binbad=0" in diag, "no corrupted binary frames", diag)
    print(f"      DIAG before: {diag0}\n      DIAG after:  {diag}")


async def one_session(device, R, verbose=True):
    async with BleakClient(device) as client:
        fx = Fixture(client)
        await fx.start()
        await asyncio.sleep(0.3)
        st = await fx.cmd("STATUS", "STATUS:")
        return st is not None


async def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--stress", type=int, default=30, help="seconds of 60 Hz binary streaming (0 = skip)")
    ap.add_argument("--cycles", type=int, default=0, help="connect/disconnect cycles")
    ap.add_argument("--persist", action="store_true", help="interactive power-cycle persistence check")
    ap.add_argument("--factory-reset", action="store_true", help="also test FACTORY_RESET (erases presets)")
    args = ap.parse_args()

    device = await find_device()
    if device is None:
        print("No ElectroBright v3 fixture found.")
        return 2

    R = Results()
    async with BleakClient(device) as client:
        fx = Fixture(client)
        await fx.start()
        await asyncio.sleep(0.3)
        original = await fx.status()
        if original is None:
            print("Fixture does not answer STATUS.")
            return 2

        await suite_handshake(fx, R)
        await suite_commands(fx, R)
        await suite_errors(fx, R)
        await suite_presets(fx, R)
        await suite_sleep_timer(fx, R)
        await suite_sound(fx, R, original[14] == 1)
        if args.stress > 0:
            await suite_stress(fx, R, args.stress)
        if args.factory_reset:
            print("\n[factory reset]")
            R.check(await fx.cmd("FACTORY_RESET", "OK") == "OK", "FACTORY_RESET replies OK (no reboot)")
            R.check(await fx.cmd("PRESET_LIST", "PRESETS:") == "PRESETS:", "no presets after reset")

        # Restore the user's look.
        r, g, b, w, br, mode = original[0:6]
        await fx.silent(f"RGBW:{r},{g},{b},{w}")
        await fx.silent(f"BRIGHTNESS:{br}")
        await fx.cmd(f"MODE:{mode}", "OK")
        if original[11] == 1:
            await fx.cmd("SLEEP", "OK")

    if args.cycles:
        print(f"\n[{args.cycles} connect/disconnect cycles]")
        ok = 0
        for i in range(args.cycles):
            try:
                ok += await one_session(device, R)
            except Exception as exc:  # noqa: BLE001 — report and continue
                print(f"      cycle {i}: {exc}")
        R.check(ok == args.cycles, f"{ok}/{args.cycles} sessions answered STATUS")

    if args.persist:
        print("\n[persistence]")
        async with BleakClient(device) as client:
            fx = Fixture(client)
            await fx.start()
            await fx.silent("RGBW:12,34,56,78")
            await fx.cmd("MODE:13", "OK")
            print("      waiting 4 s for the debounced save ...")
            await asyncio.sleep(4)
        input("      Power-cycle the fixture now, then press Enter ... ")
        device = await find_device(20)
        async with BleakClient(device) as client:
            fx = Fixture(client)
            await fx.start()
            s = await fx.status()
            R.check(s and s[0:4] == [12, 34, 56, 78] and s[5] == 13, "state survives power cycle", s)

    print(f"\n{R.passed} passed, {len(R.failed)} failed")
    for f in R.failed:
        print(f"  - {f}")
    return 0 if not R.failed else 1


if __name__ == "__main__":
    sys.exit(asyncio.run(main()))
