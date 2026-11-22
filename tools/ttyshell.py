"""Drive the board's serial console: log in (including first-login) and run commands.

usage: py ttyshell.py PORT PWFILE [--choice 1|2|3] [--timeout SECS] [--] [CMD ...]

PWFILE holds the root password. If it does not exist a random one is generated
and saved there. The factory password is tried first (that triggers the
first-login flow: set a new password, then pick SSH/Telnet/none); if the login
is refused, the PWFILE password is used. Each CMD runs in the shell with a
marker echoed afterwards so the end of its output is unambiguous.

The password is never printed except once, right after it was generated.
"""
import argparse
import os
import re
import secrets
import string
import sys
import time

import serial

FACTORY = b"changeme123"
LOGIN = re.compile(rb"login: $")
PASSWORD = re.compile(rb"(?<!New )(?<!Retype )(?<!Current )[Pp]assword: $")
NEWPW = re.compile(rb"New password: $")
RETYPE = re.compile(rb"Retype password: $")
PICK = re.compile(rb"Pick [0-9 or,]+: $")
BAD = re.compile(rb"Login incorrect")
SHELL = re.compile(rb"[#$] $")
END = re.compile(rb"\[\[END:(\d+)\]\]")


class Con:
    def __init__(self, port, baud=115200):
        self.buf = bytearray()
        self.raw = bytearray()
        deadline = time.time() + 15
        while True:
            s = serial.Serial()
            s.port, s.baudrate, s.timeout = port, baud, 0.1
            s.dtr = False
            s.rts = False
            try:
                s.open()
                break
            except (serial.SerialException, OSError):
                if time.time() > deadline:
                    raise
                time.sleep(0.3)
        self.ser = s

    def write(self, data):
        self.ser.write(data)

    def pump(self):
        data = self.ser.read(4096)
        if data:
            self.buf.extend(data)
            self.raw.extend(data)
        return data

    def expect(self, patterns, timeout):
        """Wait until one pattern matches the unread buffer; consume through it."""
        deadline = time.time() + timeout
        while True:
            snap = bytes(self.buf)  # immutable, so the match object stays valid
            for i, p in enumerate(patterns):
                m = p.search(snap)
                if m:
                    del self.buf[:m.end()]
                    return i, m, snap[:m.end()]
            if time.time() > deadline:
                return None, None, bytes(self.buf)
            self.pump()

    def drain(self, secs=0.4):
        end = time.time() + secs
        while time.time() < end:
            self.pump()
        self.buf.clear()


def clean(b):
    t = b.decode("utf-8", errors="replace")
    t = re.sub(r"\x1b\[[0-9;?]*[A-Za-z]", "", t)
    t = re.sub(r"\x1b[()][A-Za-z0-9]", "", t)
    t = t.replace("\r\n", "\n").replace("\r", "\n")
    return "".join(c if (c in "\n\t" or 32 <= ord(c) < 127) else "?" for c in t)


def get_password(path):
    if os.path.exists(path):
        return open(path).read().strip().encode(), False
    os.makedirs(os.path.dirname(path), exist_ok=True)
    alphabet = string.ascii_letters + string.digits
    pw = "".join(secrets.choice(alphabet) for _ in range(16))
    with open(path, "w") as f:
        f.write(pw + "\n")
    return pw.encode(), True


def to_prompt(con, tries=10):
    """Return 'login' or 'shell' once the console answers."""
    for _ in range(tries):
        con.drain(0.2)
        con.write(b"\r\n")
        i, _, _ = con.expect([LOGIN, SHELL], 3)
        if i == 0:
            return "login"
        if i == 1:
            return "shell"
    raise SystemExit("console did not answer with a login or shell prompt")


def login(con, user, pw, candidates, choice, log):
    """Try each candidate password in turn; answer the first-login prompts if they appear."""
    for n, cand in enumerate(candidates):
        if n and con.expect([LOGIN], 15)[0] is None:
            raise SystemExit("no login prompt after the refused password")
        con.write(user + b"\r")
        if con.expect([PASSWORD], 10)[0] is None:
            raise SystemExit("no password prompt after the user name")
        con.write(cand + b"\r")
        log("[login] attempt %d: %s" % (n + 1, "factory password" if cand == FACTORY
                                        else "saved password"))
        sent_new = 0
        refused = False
        deadline = time.time() + 900
        while time.time() < deadline:
            i, m, _ = con.expect([BAD, NEWPW, RETYPE, PICK, SHELL], 60)
            if i == 0:
                refused = True
                break
            if i in (1, 2):
                con.write(pw + b"\r")
                sent_new += 1
                log("[first-login] new password entered (%d)" % sent_new)
            elif i == 3:
                con.write(choice.encode() + b"\r")
                log("[first-login] network choice %s sent" % choice)
            elif i == 4:
                return
            else:
                log("[login] still waiting (no output for 60s); buffer tail: %r"
                    % bytes(con.buf[-120:]))
        if not refused:
            raise SystemExit("login did not finish in time")
    raise SystemExit("every candidate password was refused")


def run(con, cmd, timeout):
    con.drain(0.2)
    con.write(('%s; echo "[[END:$?]]"\r' % cmd).encode())
    i, m, before = con.expect([END], timeout)
    out = clean(before)
    code = int(m.group(1)) if m else None
    lines = [l for l in out.split("\n") if "[[END:$?]]" not in l]
    out = "\n".join(lines)
    if m:
        out = out.replace("[[END:%d]]" % code, "")
    return code, out.strip("\n")


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("port")
    ap.add_argument("pwfile")
    ap.add_argument("--choice", default="1")
    ap.add_argument("--timeout", type=float, default=60)
    ap.add_argument("--cmdfile", help="one command per line, # comments allowed")
    ap.add_argument("--dash", action="store_true",
                    help="exec dash with echo off (no readline wrapping in the output)")
    ap.add_argument("--logout", action="store_true", help="exit the shell at the end")
    ap.add_argument("cmds", nargs="*")
    a = ap.parse_args()
    if a.cmdfile:
        with open(a.cmdfile, encoding="utf-8") as f:
            a.cmds += [l.strip() for l in f if l.strip() and not l.lstrip().startswith("#")]

    pw, generated = get_password(a.pwfile)
    con = Con(a.port)

    def log(s):
        print(s, flush=True)

    state = to_prompt(con)
    log("[console] state: %s" % state)
    if state == "login":
        # Saved password first (it is the live one); factory second covers a
        # reflash that reset /etc, which re-runs first-login with the saved one.
        candidates = [FACTORY] if generated else [pw, FACTORY]
        login(con, b"root", pw, candidates, a.choice, log)
        log("[console] logged in")
        con.drain(1.0)
        con.write(b"\r")
        con.expect([SHELL], 5)
    if generated:
        log("[password] generated and saved to %s : %s" % (a.pwfile, pw.decode()))
    if a.dash:
        con.write(b"exec /usr/bin/dash\r")
        con.drain(1.5)
        con.write(b"stty -echo\r")
        con.drain(0.8)
    for cmd in a.cmds:
        code, out = run(con, cmd, a.timeout)
        print("$ %s\n%s\n[exit %s]" % (cmd, out, code), flush=True)
    if a.logout:
        con.write(b"exit\r")
        con.drain(1.5)
        log("[console] shell exited (getty will show the login prompt again)")
    con.ser.close()


main()
