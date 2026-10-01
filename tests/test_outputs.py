"""Grades the two runs test.sh made: the tracker rebuilt from the collected Swift, run once against
the shipped pass on another address and once against a held-back pass from another camera unit,
reached by name. Nothing here solves an attitude: every reported quaternion is compared with the
true attitude the pass's generator (solution/generate_pass.py) recorded for that frame, baked
into this image."""
import json
import math
import os
import re

import pytest

RUN = "/opt/run"
TRUTH = "/opt/truth"
PASSES = ["sample", "hidden"]
BORESIGHT_BAR = 6.5      # arcsec, on at least 99% of the graded frames
BORESIGHT_SHARE = 0.99
BORESIGHT_CAP = 60.0     # arcsec, on every graded frame
ROLL_BAR = 180.0         # arcsec, on every graded frame
TIME_LIMIT = 120.0
ARCSEC = 180.0 / math.pi * 3600.0
COUNTER_TOKEN = re.compile(r"^[0-9]+$")
FLOAT_TOKEN = re.compile(r"^[+-]?(?:[0-9]+\.?[0-9]*|\.[0-9]+)(?:[eE][+-]?[0-9]+)?$")


def read_text(path):
    """Opens without following a symlink, so a link planted at the path is refused."""
    fd = os.open(path, os.O_RDONLY | os.O_NOFOLLOW)
    with os.fdopen(fd, "rb") as fh:
        return fh.read().decode("utf-8", "replace")


def golden(name):
    return json.loads(read_text(os.path.join(TRUTH, "golden", name + ".json")))


def status(name):
    code, t0, t1 = read_text(os.path.join(RUN, f"status_{name}.txt")).split()
    return int(code), float(t1) - float(t0)


def report(name):
    """The run's stdout: one line per frame, the counter then w x y z separated by spaces. A
    final newline is optional."""
    code, elapsed = status(name)
    assert elapsed < TIME_LIMIT, f"the {name} run was still going at the {TIME_LIMIT:.0f} s limit"
    assert code == 0, f"the {name} run exited with status {code} instead of 0"
    text = read_text(os.path.join(RUN, f"report_{name}.txt"))
    assert text.strip(), f"the {name} run printed nothing (exit status {code})"
    lines = {}
    for n, line in enumerate(text.splitlines(), 1):
        assert line[:1].isdigit(), f"{name} line {n} does not start with the frame counter: {line[:80]!r}"
        f = [x for x in line.split(" ") if x]
        assert len(f) == 5, f"{name} line {n} is not a counter and four numbers separated by spaces: {line[:80]!r}"
        assert COUNTER_TOKEN.match(f[0]), f"{name} line {n} counter field is not a bare integer: {f[0]!r}"
        assert all(FLOAT_TOKEN.match(x) for x in f[1:]), f"{name} line {n} has a quaternion field that is not a plain number: {line[:80]!r}"
        counter = int(f[0])
        q = [float(x) for x in f[1:]]
        assert all(math.isfinite(x) for x in q), f"{name} line {n} holds a non-finite number"
        norm = math.hypot(*q)
        assert math.isfinite(norm) and norm > 0, f"{name} line {n}: the quaternion has a zero or non-finite norm"
        normalized = [x / norm for x in q]
        assert all(math.isfinite(x) for x in normalized), f"{name} line {n}: normalizing produced a non-finite component"
        lines.setdefault(counter, []).append(normalized)
    return lines


def attitude(q):
    """A = the rotation taking ICRS coordinates to camera coordinates (README.md's matrix)."""
    w, x, y, z = q
    return [[w * w + x * x - y * y - z * z, 2 * (x * y + w * z), 2 * (x * z - w * y)],
            [2 * (x * y - w * z), w * w - x * x + y * y - z * z, 2 * (y * z + w * x)],
            [2 * (x * z + w * y), 2 * (y * z - w * x), w * w - x * x - y * y + z * z]]


def errors(q_true, q_rep):
    """Boresight error (angle between the two camera +z axes) and roll error (angle between the
    camera +x axes about the true boresight), both in arcseconds."""
    n = math.sqrt(sum(c * c for c in q_true))
    at, ar = attitude([c / n for c in q_true]), attitude(q_rep)
    zt, zr = at[2], ar[2]
    cr = (zt[1] * zr[2] - zt[2] * zr[1], zt[2] * zr[0] - zt[0] * zr[2], zt[0] * zr[1] - zt[1] * zr[0])
    point = math.atan2(math.sqrt(sum(c * c for c in cr)), sum(zt[i] * zr[i] for i in range(3))) * ARCSEC
    xr = ar[0]
    d = sum(xr[i] * zt[i] for i in range(3))
    p = [xr[i] - d * zt[i] for i in range(3)]
    roll = math.atan2(sum(p[i] * at[1][i] for i in range(3)), sum(p[i] * at[0][i] for i in range(3))) * ARCSEC
    return point, abs(roll)


def graded_errors(name):
    rep, g = report(name), golden(name)
    out = {}
    for c in g["graded"]:
        out[c] = errors(g["q"][str(c)], rep[c][0])
    return out


def test_tracker_built():
    """The collected .swift files built into a binary with swiftc -O -static-stdlib."""
    assert read_text(os.path.join(RUN, "build_check.txt")).strip() == "ok", \
        "the collected Swift did not build (see the swiftc output in the log)"


@pytest.mark.parametrize("name", PASSES)
def test_one_line_per_frame(name):
    """Every frame the camera head sent has exactly one well-formed line and no other line is printed,
    and the camera head served the pass to its end."""
    rep, g = report(name), golden(name)
    missing = [c for c in g["frames"] if c not in rep]
    assert not missing, f"{name}: {len(missing)} frame(s) have no line, e.g. {missing[:5]}"
    extra = sorted(set(rep) - set(g["frames"]))
    assert not extra, f"{name}: lines for counters the camera head never sent, e.g. {extra[:5]}"
    doubled = [c for c in g["frames"] if len(rep[c]) > 1]
    assert not doubled, f"{name}: frame(s) with more than one line, e.g. {doubled[:5]}"
    log = read_text(os.path.join(RUN, f"camera_{name}.log"))
    assert " EOS " in log, f"{name}: the camera head never reached the end of the pass"


@pytest.mark.parametrize("name", PASSES)
def test_boresight_within_bars(name):
    """The boresight is within 6.5 arcsec of the truth on at least 99% of graded frames and within
    60 arcsec on every one."""
    err = graded_errors(name)
    point = sorted((e[0], c) for c, e in err.items())
    over = [(round(p, 2), c) for p, c in point if p > BORESIGHT_BAR]
    allowed = int((1.0 - BORESIGHT_SHARE) * len(point))
    assert len(over) <= allowed, (f"{name}: {len(over)} of {len(point)} graded frames have the boresight more than "
                                  f"{BORESIGHT_BAR} arcsec off (at most {allowed} may), worst {over[-5:]}")
    assert point[-1][0] <= BORESIGHT_CAP, f"{name}: frame {point[-1][1]} has the boresight {point[-1][0]:.1f} arcsec off"


@pytest.mark.parametrize("name", PASSES)
def test_roll_within_3_arcmin(name):
    """The roll about the boresight is within 180 arcsec of the truth on every graded frame."""
    err = graded_errors(name)
    bad = sorted(((round(e[1], 1), c) for c, e in err.items() if e[1] > ROLL_BAR), reverse=True)
    assert not bad, f"{name}: {len(bad)} graded frame(s) with the roll more than {ROLL_BAR:.0f} arcsec off, worst {bad[:5]}"
