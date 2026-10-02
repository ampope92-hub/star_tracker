# Star tracker bench

GNC lab notes for the STU camera heads on the replay bench. The camera head plays back a
recorded pass exactly as the unit sent it down: the flight camera does its own spot finding
and centroiding, so what comes over the link is a list of spots per frame, not images.

## The link

TCP to `CAMERA_HOST` and `CAMERA_PORT` from the environment. `CAMERA_HOST` is a host name or
an address. ASCII lines ending in LF both ways.

On connect the camera head sends

    STC1 <unit> f=<focal length, px> size=<detector side, px> link=<n>

and waits for `START <counter>`. It then sends every frame of the pass whose counter is
`<counter>` or later, in counter order, each frame as

    FRAME <counter> <exposure ms> <vx> <vy> <vz> <spots>
    <x> <y> <counts>
    ...

with one line per spot after the `FRAME` line. `START 0` gets the pass from the beginning.

- The bench link carries `n` frames per connection (`link=` in that connection's greeting).
  After the `n`-th frame the camera head writes `LINK DOWN` and closes. A new connection
  and a new `START` pick up from any counter.
- After the last frame of the pass it writes `EOS` and closes.
- A connection that has not sent `START` within 10 seconds is closed without a word.
  Anything other than `START <counter>` gets `ERR <text>`.

## Frames

- The counter goes up by one every 0.1 s. While the spacecraft slews faster than the camera
  can centroid, the camera head sends nothing, so the counter jumps.
- `vx vy vz`: the spacecraft's velocity relative to the solar-system barycentre, ICRS axes,
  km/s, as the navigation filter had it at mid-exposure. The camera head replays frames the
  flight unit recorded in orbit; the spots are where the stars appeared on the detector at
  the time of each exposure.
- A spot is `x` (detector column) and `y` (detector row) in pixels, pixel centres at whole
  numbers from 0 to `size - 1`, and the spot's summed signal in counts.
- Not every spot is a star. The detector has a few hot pixels, particle hits land anywhere,
  planets are not in the catalogue, and when the Earth is in the field (eclipse) the limb
  throws glints and no stars get through. Two stars closer than about 2.5 px come out as one
  spot, stars too faint for the exposure are not reported, and now and then a star that
  should have been is missed.

## Camera geometry

Camera axes: +z is the boresight, out through the lens toward the sky; +x points toward
increasing column and +y toward increasing row. The optical axis meets the detector at its
centre, ((size - 1)/2, (size - 1)/2).

The lens puts a direction with camera coordinates (X, Y, Z) at

    centre + f (1 + k (u² + v²)) (u, v),    u = X/Z,  v = Y/Z

The `f` in the greeting is the focal length on the unit's lens drawing, and the drawing's `k`
is zero. Built units come out within 1% of their drawing focal length, with `k` anywhere
from -0.25 to 0.25. None of the bench units has been calibrated since it was integrated.

## The catalogue

The file at `STAR_CATALOG`: `#` lines are comments, every other line is

    <id> <right ascension, deg> <declination, deg> <V magnitude>

ICRS directions as seen from the solar-system barycentre at the epoch of the pass (proper
motion already applied). `/app/sky/catalog.txt` is the 9,000-star commissioning catalogue.
Flight catalogues are cut deeper, to V 9, and hold up to 60,000 stars.

## Attitude

The attitude of a frame is the rotation that takes ICRS coordinates to camera coordinates at
mid-exposure, `v_cam = A v_icrs`, written as the unit quaternion `(w, x, y, z)` with

    A = | w²+x²-y²-z²   2(xy+wz)      2(xz-wy)    |
        | 2(xy-wz)      w²-x²+y²-z²   2(yz+wx)    |
        | 2(xz+wy)      2(yz-wx)      w²-x²-y²+z² |

so the third row of `A` is the boresight in ICRS. `q` and `-q` are the same attitude.
