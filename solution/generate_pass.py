#!/usr/bin/env python3
"""Builds one star-tracker pass: a star catalogue, the camera head's frame stream and the true
attitude of every frame.

    python3 generate_pass.py --pass sample --out DIR       (the shipped pass)
    python3 generate_pass.py --pass hidden --out DIR       (the held-back pass)
    python3 generate_pass.py --pass sample --seed 7 --out DIR   (a fresh draw of that pass's design)

Everything is drawn from a model written down first. A catalogue of stars uniform on the sky,
with a magnitude law. A spacecraft in low Earth orbit whose velocity relative to the solar-system
barycentre is Earth's orbital velocity plus its own orbital velocity. An attitude profile made of
slow tracking arcs, slews during which the camera sends nothing, and eclipses during which the
Earth fills the field and no star is seen. Every star's apparent direction is its catalogue
direction aberrated by that velocity (the exact special-relativistic formula), turned into the
camera frame by the true attitude and imaged through the unit's real optics:

    pixel = centre + f (1 + k (u^2 + v^2)) (u, v),   (u, v) = (X/Z, Y/Z) in the camera frame

with f and k the unit's real values, which differ from the drawing values the camera head
announces. Spot brightness follows the star's magnitude and the exposure; centroids carry noise
that grows for faint spots; spots closer than 2.5 px blend into one. Hot pixels sit at fixed
detector positions in every frame, particle hits land at random, and a planet that is not in the
catalogue is bright wherever it falls in the field.

Writes DIR/catalog.txt, DIR/pass.txt (the camera head's wire format, preceded by one UNIT line)
and DIR/truth.json (the list of graded frames, those in which at least six catalogue stars were
detected, and the true attitude quaternion (w, x, y, z) of each). The shipped files are these
outputs: environment/camera/pass.txt and environment/app/sky/catalog.txt are the sample pass,
tests/data/<pass>/ and tests/golden/<pass>.json the two graded passes.
"""
import argparse
import json
import math
import os
import random

C_KM_S = 299792.458
SIZE = 1024
CX = CY = 511.5
EDGE = 2.0

PASSES = {
    # Shipped pass: the small commissioning catalogue, unit STU-A.
    "sample": {"seed": 424242, "n_cat": 9000, "m_min": -1.2, "m_max": 6.6, "unit": "STU-A",
               "f0": 4871.0, "df": +0.0042, "k": -0.21, "gain": 1035.0, "thresh": 250,
               "frames": 6000, "day": 81.0, "raan": 35.0, "incl": 51.6, "u0": 10.0, "c0": 48210,
               "hot": 4, "planet": (64.0, 21.5)},
    # Held-back pass: another sky, a flight catalogue of 60,000 stars, unit STU-C with other optics,
    # another season (so another direction of Earth's velocity) and another orbit.
    "hidden": {"seed": 90210, "n_cat": 60000, "m_min": -1.2, "m_max": 8.5, "unit": "STU-C",
               "f0": 4120.0, "df": -0.0047, "k": +0.22, "gain": 1530.0, "thresh": 260,
               "frames": 12000, "day": 262.0, "raan": 200.0, "incl": 97.8, "u0": 250.0, "c0": 7015,
               "hot": 5, "planet": (301.0, -18.0)},
}


# ---------------------------------------------------------------- vectors and attitude
def unit_radec(ra, dec):
    ra, dec = math.radians(ra), math.radians(dec)
    return (math.cos(dec) * math.cos(ra), math.cos(dec) * math.sin(ra), math.sin(dec))


def dot(a, b):
    return a[0] * b[0] + a[1] * b[1] + a[2] * b[2]


def cross(a, b):
    return (a[1] * b[2] - a[2] * b[1], a[2] * b[0] - a[0] * b[2], a[0] * b[1] - a[1] * b[0])


def norm(a):
    n = math.sqrt(dot(a, a))
    return (a[0] / n, a[1] / n, a[2] / n)


def matmul(A, B):
    return [[sum(A[i][k] * B[k][j] for k in range(3)) for j in range(3)] for i in range(3)]


def matvec(A, v):
    return (A[0][0] * v[0] + A[0][1] * v[1] + A[0][2] * v[2],
            A[1][0] * v[0] + A[1][1] * v[1] + A[1][2] * v[2],
            A[2][0] * v[0] + A[2][1] * v[1] + A[2][2] * v[2])


def rot_axis(axis, ang):
    """Rotation matrix turning vectors by +ang about the unit axis."""
    x, y, z = axis
    c, s = math.cos(ang), math.sin(ang)
    t = 1.0 - c
    return [[t * x * x + c, t * x * y - s * z, t * x * z + s * y],
            [t * x * y + s * z, t * y * y + c, t * y * z - s * x],
            [t * x * z - s * y, t * y * z + s * x, t * z * z + c]]


def a_from_q(q):
    """Attitude matrix of q = (w, x, y, z): v_cam = A v_icrs (the convention README.md prints)."""
    w, x, y, z = q
    return [[w * w + x * x - y * y - z * z, 2 * (x * y + w * z), 2 * (x * z - w * y)],
            [2 * (x * y - w * z), w * w - x * x + y * y - z * z, 2 * (y * z + w * x)],
            [2 * (x * z + w * y), 2 * (y * z - w * x), w * w - x * x - y * y + z * z]]


def q_from_a(A):
    tr = A[0][0] + A[1][1] + A[2][2]
    cands = [
        (1 + tr, (1 + tr, A[1][2] - A[2][1], A[2][0] - A[0][2], A[0][1] - A[1][0])),
        (1 + 2 * A[0][0] - tr, (A[1][2] - A[2][1], 1 + 2 * A[0][0] - tr, A[0][1] + A[1][0], A[0][2] + A[2][0])),
        (1 + 2 * A[1][1] - tr, (A[2][0] - A[0][2], A[0][1] + A[1][0], 1 + 2 * A[1][1] - tr, A[1][2] + A[2][1])),
        (1 + 2 * A[2][2] - tr, (A[0][1] - A[1][0], A[0][2] + A[2][0], A[1][2] + A[2][1], 1 + 2 * A[2][2] - tr)),
    ]
    _, v = max(cands, key=lambda c: c[0])
    n = math.sqrt(sum(c * c for c in v))
    q = [c / n for c in v]
    if q[0] < 0:
        q = [-c for c in q]
    return q


def random_attitude(rng):
    # uniform random rotation from a uniform quaternion
    u1, u2, u3 = rng.random(), rng.random(), rng.random()
    q = (math.sqrt(1 - u1) * math.sin(2 * math.pi * u2), math.sqrt(1 - u1) * math.cos(2 * math.pi * u2),
         math.sqrt(u1) * math.sin(2 * math.pi * u3), math.sqrt(u1) * math.cos(2 * math.pi * u3))
    return a_from_q(q)


def attitude_looking_at(rng, target, within_deg):
    """A random attitude whose boresight is within within_deg of target."""
    while True:
        A = random_attitude(rng)
        z = tuple(A[2])
        # rotate the boresight onto a point near the target
        off = math.radians(within_deg) * math.sqrt(rng.random())
        perp = norm(cross(target, (0.3, -0.5, 0.8) if abs(target[2]) < 0.9 else (1.0, 0.0, 0.0)))
        perp = matvec(rot_axis(target, rng.uniform(0, 2 * math.pi)), perp)
        want = norm(tuple(math.cos(off) * target[i] + math.sin(off) * perp[i] for i in range(3)))
        axis = cross(z, want)
        s = math.sqrt(dot(axis, axis))
        if s < 1e-9:
            return A
        ang = math.atan2(s, dot(z, want))
        R = rot_axis(norm(axis), ang)
        # A maps icrs->cam; new boresight row = R z  -> rows of A times R^T
        Rt = [[R[j][i] for j in range(3)] for i in range(3)]
        return matmul(A, Rt)


# ---------------------------------------------------------------- physics
def aberrate(u, beta):
    """Apparent direction of a star at catalogue direction u for an observer moving at beta = v/c."""
    b2 = dot(beta, beta)
    g = 1.0 / math.sqrt(1.0 - b2)
    ub = dot(u, beta)
    f = g * g / (1.0 + g)
    num = tuple(u[i] + g * beta[i] + f * ub * beta[i] for i in range(3))
    den = g * (1.0 + ub)
    return norm(tuple(c / den for c in num))


def velocity(cfg, t):
    """Spacecraft velocity relative to the barycentre, ICRS axes, km/s, at t seconds into the pass."""
    eps = math.radians(23.4393)
    lam = math.radians((cfg["day"] - 80.0) * 360.0 / 365.25 + t / 86400.0 * 360.0 / 365.25)
    # Earth's velocity in ecliptic coordinates is perpendicular to the Sun-Earth line.
    ve = 29.78
    vx, vy = -ve * math.sin(lam + math.pi), ve * math.cos(lam + math.pi)
    earth = (vx, vy * math.cos(eps), vy * math.sin(eps))
    # circular low orbit
    om, inc = math.radians(cfg["raan"]), math.radians(cfg["incl"])
    period = 5760.0
    vo = 7.62
    u = math.radians(cfg["u0"]) + 2 * math.pi * t / period
    e1 = (math.cos(om), math.sin(om), 0.0)
    e2 = (-math.sin(om) * math.cos(inc), math.cos(om) * math.cos(inc), math.sin(inc))
    orb = tuple(vo * (-math.sin(u) * e1[i] + math.cos(u) * e2[i]) for i in range(3))
    return tuple(earth[i] + orb[i] for i in range(3))


# ---------------------------------------------------------------- catalogue
def make_catalogue(rng, cfg):
    n, m0, m1 = cfg["n_cat"], cfg["m_min"], cfg["m_max"]
    a = 0.45 * math.log(10.0)
    lo, hi = math.exp(a * m0), math.exp(a * m1)
    ids = rng.sample(range(100000, 999999), n)
    stars = []
    for i in range(n):
        z = rng.uniform(-1.0, 1.0)
        ra = rng.uniform(0.0, 360.0)
        dec = math.degrees(math.asin(z))
        m = math.log(lo + (hi - lo) * rng.random()) / a
        stars.append((ids[i], round(ra, 6), round(dec, 6), round(m, 2)))
    stars.sort()
    return stars


# ---------------------------------------------------------------- the pass
def plan_segments(rng, cfg):
    """Tracking arcs separated by slews (nothing sent) and eclipses (frames with no stars)."""
    segs = []
    total = cfg["frames"]
    sent = 0
    planet_arc = rng.randrange(2, 5)
    arc = 0
    while sent < total:
        n = rng.randint(380, 1100)
        n = min(n, total - sent)
        segs.append(("track", n, arc == planet_arc))
        sent += n
        arc += 1
        if sent >= total:
            break
        kind = "slew" if rng.random() < 0.55 else "eclipse"
        if kind == "slew":
            segs.append(("slew", rng.randint(250, 900), False))       # frames skipped, 25 to 90 s
        else:
            e = rng.randint(180, 420)
            e = min(e, total - sent)
            segs.append(("eclipse", e, False))
            sent += e
    return segs


def new_rate(rng):
    axis = norm((rng.gauss(0, 1), rng.gauss(0, 1), rng.gauss(0, 1)))
    rate = math.radians(rng.uniform(0.04, 0.22))    # rad/s
    return axis, rate


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--pass", dest="which", required=True, choices=sorted(PASSES))
    ap.add_argument("--seed", type=int, default=None)
    ap.add_argument("--out", required=True)
    args = ap.parse_args()
    cfg = dict(PASSES[args.which])
    if args.seed is not None:
        cfg["seed"] = cfg["seed"] * 1000 + args.seed
        cfg["c0"] = 1000 + (args.seed * 7919) % 60000
    rng = random.Random(cfg["seed"])
    os.makedirs(args.out, exist_ok=True)

    stars = make_catalogue(rng, cfg)
    f_true = cfg["f0"] * (1.0 + cfg["df"])
    k_true = cfg["k"]
    gain, thresh = cfg["gain"], cfg["thresh"]

    # Only stars that can ever reach the detection threshold are imaged; the rest are too faint.
    max_exp = 160.0
    m_vis = -2.5 * math.log10(thresh * 0.8 / (gain * max_exp))
    vis = [(s[0], unit_radec(s[1], s[2]), s[3]) for s in stars if s[3] <= m_vis]
    # coarse index of visible stars by declination band and RA cell
    cell = 4.0
    grid = {}
    for sid, u, m in vis:
        dec = math.degrees(math.asin(max(-1.0, min(1.0, u[2]))))
        ra = math.degrees(math.atan2(u[1], u[0])) % 360.0
        grid.setdefault((int((dec + 90) // cell), int(ra // cell)), []).append((sid, u, m))

    half_fov = math.degrees(math.atan(math.hypot(SIZE / 2, SIZE / 2) / (f_true * 0.98))) + 0.6

    def near(bore):
        dec = math.degrees(math.asin(max(-1.0, min(1.0, bore[2]))))
        ra = math.degrees(math.atan2(bore[1], bore[0])) % 360.0
        out = []
        b0 = int((dec - half_fov + 90) // cell)
        b1 = int((dec + half_fov + 90) // cell)
        cosd = max(math.cos(math.radians(min(89.9, abs(dec) + half_fov))), 1e-3)
        span = half_fov / cosd
        for b in range(max(0, b0), min(int(180 // cell), b1) + 1):
            if span >= 180:
                cells = range(int(360 // cell))
            else:
                r0 = int(((ra - span) % 360.0) // cell)
                ncell = int(2 * span // cell) + 2
                cells = [(r0 + j) % int(360 // cell) for j in range(ncell + 1)]
            for c in set(cells):
                out.extend(grid.get((b, c), ()))
        return out

    hot = [(float(rng.randint(40, SIZE - 40)), float(rng.randint(40, SIZE - 40)), rng.uniform(6.0, 22.0)) for _ in range(cfg["hot"])]
    planet_u = unit_radec(*cfg["planet"])

    segs = plan_segments(rng, cfg)
    t = 0.0
    counter = cfg["c0"]
    A0 = random_attitude(rng)
    axis, rate = new_rate(rng)
    t_seg = 0.0
    exposure = 80
    lines_out = []
    truth = {}
    graded = []
    stats = {"frames": 0, "graded": 0, "slews": 0, "eclipses": 0, "spots": 0, "star_spots": 0, "blends": 0,
             "planet_frames": 0, "max_aberr": 0.0}

    def attitude(tt):
        return matmul(rot_axis(axis, -rate * (tt - t_seg)), A0)

    for idx, (kind, n, want_planet) in enumerate(segs):
        if kind == "slew":
            stats["slews"] += 1
            t += n / 10.0
            counter += n
            A0 = random_attitude(rng)
            axis, rate = new_rate(rng)
            t_seg = t
            continue
        if kind == "track" and idx > 0 and segs[idx - 1][0] == "slew" and want_planet:
            A0 = attitude_looking_at(rng, planet_u, 3.0)
            t_seg = t
        if kind == "track" and idx == 0 and want_planet:
            A0 = attitude_looking_at(rng, planet_u, 3.0)
        if kind == "eclipse":
            stats["eclipses"] += 1
        for _ in range(n):
            if rng.random() < 0.004:
                exposure = rng.choice([40, 60, 80, 100, 120, 160])
            A = attitude(t)
            v = velocity(cfg, t)
            beta = tuple(c / C_KM_S for c in v)
            bore = tuple(A[2])
            spots = []   # (x, y, counts, star ids)
            if kind == "track":
                cands = near(bore)
                for sid, u, m in cands:
                    ua = aberrate(u, beta)
                    c = matvec(A, ua)
                    if c[2] <= 0.0:
                        continue
                    uu, vv = c[0] / c[2], c[1] / c[2]
                    rho2 = uu * uu + vv * vv
                    s = f_true * (1.0 + k_true * rho2)
                    x, y = CX + s * uu, CY + s * vv
                    if not (EDGE <= x <= SIZE - 1 - EDGE and EDGE <= y <= SIZE - 1 - EDGE):
                        continue
                    flux = gain * exposure * 10 ** (-0.4 * m)
                    counts = flux * (1.0 + 0.03 * rng.gauss(0, 1)) + math.sqrt(flux) * rng.gauss(0, 1)
                    if counts < thresh or rng.random() < 0.03:
                        continue
                    sig = 0.01 + 1.2 / math.sqrt(counts)
                    spots.append([x + sig * rng.gauss(0, 1), y + sig * rng.gauss(0, 1), min(counts, 65535.0), [sid]])
                    ab = math.degrees(math.acos(max(-1.0, min(1.0, dot(u, ua))))) * 3600
                    stats["max_aberr"] = max(stats["max_aberr"], ab)
                # the planet
                ua = aberrate(planet_u, beta)
                c = matvec(A, ua)
                if c[2] > 0:
                    uu, vv = c[0] / c[2], c[1] / c[2]
                    rho2 = uu * uu + vv * vv
                    s = f_true * (1.0 + k_true * rho2)
                    x, y = CX + s * uu, CY + s * vv
                    if EDGE <= x <= SIZE - 1 - EDGE and EDGE <= y <= SIZE - 1 - EDGE:
                        spots.append([x + 0.05 * rng.gauss(0, 1), y + 0.05 * rng.gauss(0, 1), 65535.0, []])
                        stats["planet_frames"] += 1
            else:
                # Earth in the field: stray light, a couple of glints on the limb
                for _ in range(rng.randint(0, 3)):
                    spots.append([rng.uniform(5, SIZE - 6), rng.uniform(5, SIZE - 6), rng.uniform(3000, 65535), []])
            for hx, hy, hr in hot:
                spots.append([hx, hy, min(65535.0, hr * exposure * (1 + 0.02 * rng.gauss(0, 1))), []])
            nh = 0
            lam = 0.6
            L = math.exp(-lam)
            p = rng.random()
            while p > L:
                nh += 1
                p *= rng.random()
            for _ in range(nh):
                spots.append([rng.uniform(3, SIZE - 4), rng.uniform(3, SIZE - 4), rng.uniform(260, 2000), []])
            # blend spots closer than 2.5 px
            merged = []
            spots.sort(key=lambda s: -s[2])
            for s in spots:
                for mrg in merged:
                    if (mrg[0] - s[0]) ** 2 + (mrg[1] - s[1]) ** 2 < 2.5 ** 2:
                        w1, w2 = mrg[2], s[2]
                        mrg[0] = (mrg[0] * w1 + s[0] * w2) / (w1 + w2)
                        mrg[1] = (mrg[1] * w1 + s[1] * w2) / (w1 + w2)
                        mrg[2] = min(65535.0, w1 + w2)
                        mrg[3] = mrg[3] + s[3]
                        mrg.append("blend")
                        stats["blends"] += 1
                        break
                else:
                    merged.append(s)
            rng.shuffle(merged)
            nstar = sum(1 for s in merged if len(s[3]) == 1 and len(s) == 4)
            stats["frames"] += 1
            stats["spots"] += len(merged)
            stats["star_spots"] += nstar
            lines_out.append(f"FRAME {counter} {exposure} {v[0]:.4f} {v[1]:.4f} {v[2]:.4f} {len(merged)}")
            for s in merged:
                lines_out.append(f"{s[0]:.3f} {s[1]:.3f} {round(s[2])}")
            if nstar >= 6:
                graded.append(counter)
                truth[str(counter)] = [round(c, 10) for c in q_from_a(A)]
                stats["graded"] += 1
            t += 0.1
            counter += 1

    with open(os.path.join(args.out, "catalog.txt"), "w") as fh:
        fh.write(f"# {len(stars)} stars: id, right ascension (deg), declination (deg), V magnitude\n")
        for s in stars:
            fh.write(f"{s[0]} {s[1]:.6f} {s[2]:.6f} {s[3]:.2f}\n")
    with open(os.path.join(args.out, "pass.txt"), "w") as fh:
        fh.write(f"UNIT {cfg['unit']} {cfg['f0']:.1f} {SIZE}\n")
        fh.write("\n".join(lines_out) + "\n")
    with open(os.path.join(args.out, "truth.json"), "w") as fh:
        json.dump({"unit": cfg["unit"], "graded": graded, "q": truth}, fh, separators=(",", ":"))
    stats["f_true"], stats["k_true"] = f_true, k_true
    stats["segments"] = [[k, n] for k, n, _ in segs]
    print(json.dumps(stats))


if __name__ == "__main__":
    main()
