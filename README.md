# Spacecraft Star Tracker (Attitude Determination in Swift)

A GNC bench replays recorded star-tracker passes through a camera head, and the attitude solver still has to be written. The agent writes it in Swift using only the standard library (no Foundation, no Dispatch): the program connects over TCP to the camera head (`CAMERA_HOST`/`CAMERA_PORT`), reads per-frame spot lists, exposure and spacecraft velocity, resumes after every `LINK DOWN`, identifies stars against the catalogue at `STAR_CATALOG`, and prints one line per frame: the frame counter and the camera's inertial attitude quaternion `w x y z`. This is a multi-container task: the camera head runs as its own service.

## What makes it hard

Each shortcut below produces a smooth, plausible attitude history with small residuals, so nothing in the program's own output signals that it is wrong. Figures are pointing-axis error at the 99th percentile on the shipped / held-back pass, against a 6.5 arc-second bar.

- **Stellar aberration.** The spacecraft moves at 25-34 km/s relative to the solar system barycentre, shifting every star toward the velocity apex by up to 23 arc seconds. The velocity is in every frame header with no hint of its purpose. Ignoring it: 21.7 / 22.8 arcsec.
- **Uncalibrated optics.** The true focal length and third-order distortion differ from the lens drawing the camera announces and must be recovered from the matched stars. Drawing values: 28.1 / 23.4 arcsec; fitting focal length only: 12.5 / 15.0. The reference, fitting both jointly with the attitudes, reaches 1.9 / 1.5.
- **Identification that scales.** The held-back pass uses a 60,000-star flight catalogue against 9,000 shipped. A full triangle index (9.55 million triangles on the shipped sky) works there but runs out of the 2 GiB address-space limit on the flight catalogue before solving a frame; so does a pair index over every star.
- **Flight conditions.** Hot pixels, particle hits, a planet and blended stars among the spots, eclipses and slews that force lost-in-space reacquisition, and a sky that includes the celestial pole.

## How it's graded

The verifier runs in a separate container and collects only `/app/tracker`. It copies the regular `.swift` files at its top level into a root-owned directory and builds them as an unprivileged user with `swiftc -O -static-stdlib`, on a toolchain with the Foundation, Dispatch and test-framework module interfaces removed. It then starts its own camera head twice and runs the binary against each:

1. The shipped pass on a different address (127.0.0.3) and port, with different link lengths.
2. A held-back pass from another camera unit with other optics, another sky with the 60,000-star catalogue, another season and orbit: 12,000 frames, 10,334 graded, reached by host name.

Each run must finish within 120 s of wall time, exit 0, and print exactly one parseable line per frame sent. On frames with at least six detected catalogue stars, the pointing axis must be within 6.5 arcsec of the truth on at least 99% of frames and within 60 arcsec on all, and roll within 3 arcmin on all. The camera head's log must show the end of the pass. Over the shipped and held-back passes plus eight fresh seeds of each, the reference reaches at most 2.6 arcsec at the 99th percentile and the nearest wrong route at least 10.6; the bar sits at the midpoint.

Anti-cheat: the binary runs with a clean environment, a 2 GiB address-space limit and a seccomp launcher (`tests/launch.c`) that blocks any further `exec`. True attitudes are baked into the verifier image root-only; tests, passes, camera head and logs are closed to the build user and probed before the run; pytest runs by absolute path in isolated mode and opens files with `O_NOFOLLOW`. The task.toml verification write-up lists the one-edit wrong variants of the reference (no aberration, drawing optics, focal length only, naive full triangle index, literal host, no resume after `LINK DOWN`, quarter-turn roll, extra or missing lines) confirmed to score 0.

## Repository layout

- `instruction.md` - the task prompt given to the agent.
- `task.toml` - metadata, difficulty/solution/verification write-ups, timeouts and network policy.
- `environment/` - agent image (`Dockerfile`), camera-head image (`Dockerfile.camera`, `camera/` with the shipped pass), `docker-compose.yaml`, the star catalogue in `app/sky/`, and the link/frame/geometry README in `app/tracker/`.
- `solution/` - reference `main.swift` (bright-star pair-angle index, triangle matching, Davenport q-method tracking, relativistic aberration, joint optics calibration), `solve.sh`, and `generate_pass.py`, which rebuilds both passes and golden files byte for byte.
- `tests/` - verifier image, `test.sh`, `test_outputs.py`, the seccomp launcher `launch.c`, the camera head, both passes and catalogues, and the true attitudes (`golden/`).

## Running it

Requires Docker and Harbor (`uv tool install harbor` or `pip install harbor`). From the repo root:

```
harbor run -p . -a oracle
```

runs the reference solution through the verifier (should score reward 1). To try an agent instead:

```
harbor run -p . -a <agent> -m <model>
```

for example `-a claude-code`.

---

Task design, data generators, reference solution and verifier by Audrey Pope.
