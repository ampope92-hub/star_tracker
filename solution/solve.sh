#!/bin/bash
# Oracle. Puts the reference tracker in place and builds it the way the grader does.
#
# main.swift reads the whole pass from the camera head, resuming after every link drop, flags
# the detector's hot pixels (spots on the same pixel in many frames, on both sides of a slew), and
# solves each frame: a lost-in-space solve (triangles of the brightest spots against a sorted
# pair-angle index of the brightest catalogue stars, every hypothesis verified against the
# whole field) starts each tracking arc, tracking carries the attitude between frames and falls
# back to lost in space after a slew or an eclipse. The unit's focal length and third-order
# distortion are then fitted to every matched star jointly with the attitudes, and the pass is
# solved again with the fitted optics. Catalogue directions are aberrated by each frame's
# barycentric velocity before they are compared with the camera, so the attitude printed is
# the geometric one, one line per frame. generate_pass.py rebuilds the shipped and held-back passes.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cp "$HERE/main.swift" /app/tracker/main.swift
cd /app/tracker
swiftc -O -static-stdlib -o /app/tracker/tracker /app/tracker/main.swift
