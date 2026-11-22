"""Capture a serial port for N seconds, surviving USB re-enumeration.

usage: py capture.py PORT SECONDS LOGFILE [--baud N] [--reset] [--send SECS:TEXT]

DTR stays low so opening the port never selects the ROM bootloader. The open
is retried and a read error closes and reopens the port, because the
ESP32-S3 USB-Serial/JTAG device can disappear and come back around a reset.
--reset pulses RTS (EN low) once the port is open, so the log starts at the
chip's first boot message. Raw bytes go to LOGFILE; a printable ASCII
rendering goes to stdout.
"""
import argparse
import re
import time

import serial

ap = argparse.ArgumentParser()
ap.add_argument("port")
ap.add_argument("seconds", type=float)
ap.add_argument("logfile")
ap.add_argument("--baud", type=int, default=115200)
ap.add_argument("--reset", action="store_true")
ap.add_argument("--dtr", action="store_true", help="assert DTR (never combine with --reset: IO0 low enters the ROM bootloader)")
ap.add_argument("--send", action="append", default=[],
                help="SECS:TEXT (repeatable), TEXT takes \\r \\n escapes")
args = ap.parse_args()

sends = []
for item in args.send:
    when, _, text = item.partition(":")
    sends.append([float(when), text.encode().decode("unicode_escape").encode(), False])

t0 = time.time()
deadline = t0 + args.seconds
ser = None
opens = []
buf = bytearray()
did_reset = False


def stamp():
    return time.time() - t0


def try_open():
    s = serial.Serial()
    s.port = args.port
    s.baudrate = args.baud
    s.timeout = 0.2
    s.dtr = args.dtr
    s.rts = False
    s.open()
    return s


while time.time() < deadline:
    if ser is None:
        try:
            ser = try_open()
            opens.append(round(stamp(), 1))
        except (serial.SerialException, OSError):
            time.sleep(0.2)
            continue
    try:
        if args.reset and not did_reset:
            did_reset = True
            ser.dtr = False
            ser.rts = True
            time.sleep(0.1)
            ser.rts = False
        for item in sends:
            if not item[2] and stamp() >= item[0]:
                ser.write(item[1])
                item[2] = True
        data = ser.read(4096)
        if data:
            buf.extend(data)
    except (serial.SerialException, OSError):
        try:
            ser.close()
        except Exception:
            pass
        ser = None

if ser is not None:
    ser.close()

with open(args.logfile, "wb") as f:
    f.write(buf)

text = buf.decode("utf-8", errors="replace")
text = re.sub(r"\x1b\[[0-9;?]*[A-Za-z]", "", text)
text = text.replace("\r\n", "\n").replace("\r", "\n")
text = "".join(c if (c == "\n" or c == "\t" or 32 <= ord(c) < 127) else "?" for c in text)
print("[capture] port=%s opens_at=%s bytes=%d" % (args.port, opens or "never", len(buf)))
print(text)
