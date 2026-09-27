# Agent image: the Swift 5.10 toolchain, the tracker's directory and the commissioning star
# catalogue. The recorded pass is not here; it lives in the camera head's own image
# (Dockerfile.camera) and is only reachable over its socket. Nothing from tests/ or solution/
# is copied in.
#
# Base image: not on the canonical list because the task targets a language the list does not
# cover. Swift has no canonical Terminal-Bench base, and the official swift:5.10-jammy image is
# the toolchain the grader builds with (Ubuntu 22.04 underneath, the same distro family as the
# canonical ubuntu entry).
FROM swift@sha256:ffc42e399ad0cad324f68d58f65e4d5f2c22eb9df73c4dfa249e898d497254b3

RUN apt-get update \
    && apt-get install -y --no-install-recommends \
        asciinema \
        ca-certificates \
        tmux \
    && rm -rf /var/lib/apt/lists/*

# The tracker is written against the Swift standard library and Glibc only. The Foundation,
# Dispatch and XCTest module interfaces (and Foundation's static archives) are removed, so
# importing them does not compile here or in the grader. The toolchain's own shared libraries
# stay: the compiler driver links against them, and libdispatch.a stays because the static
# standard library links it.
RUN rm -rf /usr/lib/swift/linux/x86_64/Foundation*.swift* /usr/lib/swift/linux/x86_64/XCTest.swift* \
           /usr/lib/swift_static/linux/x86_64/Foundation*.swift* \
           /usr/lib/swift_static/linux/libFoundation*.a /usr/lib/swift_static/linux/libCoreFoundation.a \
           /usr/lib/swift_static/linux/libCFURLSessionInterface.a /usr/lib/swift_static/linux/libCFXMLInterface.a \
           /usr/lib/swift/CoreFoundation /usr/lib/swift_static/CoreFoundation \
           /usr/lib/swift/linux/x86_64/Dispatch.swift* /usr/lib/swift_static/linux/x86_64/Dispatch.swift* \
           /usr/lib/swift/dispatch /usr/lib/swift_static/dispatch

ENV CAMERA_HOST=127.0.0.1 \
    CAMERA_PORT=7400 \
    STAR_CATALOG=/app/sky/catalog.txt

COPY app/sky/ /app/sky/
COPY app/tracker/ /app/tracker/
WORKDIR /app/tracker

# Warm the module cache so the first build compiles only the tracker's own code.
RUN mkdir -p /tmp/warm && printf 'import Glibc\nprint(sqrt(2.0))\n' > /tmp/warm/main.swift \
    && swiftc -O -static-stdlib -o /tmp/warm/warm /tmp/warm/main.swift && /tmp/warm/warm \
    && rm -rf /tmp/warm
