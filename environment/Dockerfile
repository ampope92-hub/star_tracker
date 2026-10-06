# Agent image: the Swift 5.10.1 toolchain, the tracker's directory and the commissioning star
# catalogue. The recorded pass is not here; it lives in the camera head's own image
# (Dockerfile.camera) and is only reachable over its socket. Nothing from tests/ or solution/
# is copied in.
#
# The Swift 5.10.1 toolchain, from swift.org's Ubuntu 24.04 release tarball: pinned by sha256 and
# checked against the release's PGP signature (Swift 5.x release key, fingerprint
# A62AE125BBBFBB96A6E042EC925CC1CCED3D1561). Fetched in a throwaway stage so curl and gpg stay out.
FROM public.ecr.aws/docker/library/ubuntu:24.04@sha256:0d39fcc8335d6d74d5502f6df2d30119ff4790ebbb60b364818d5112d9e3e932 AS swift_fetch
ARG SWIFT_URL=https://download.swift.org/swift-5.10.1-release/ubuntu2404/swift-5.10.1-RELEASE/swift-5.10.1-RELEASE-ubuntu24.04.tar.gz
ARG SWIFT_SHA256=e1a56752d80b2b759d9ccceae548bd8bdf21674c2b807b0a2738fdb0ba7034ef
ARG SWIFT_KEY_FPR=A62AE125BBBFBB96A6E042EC925CC1CCED3D1561
RUN apt-get update \
    && apt-get install -y --no-install-recommends ca-certificates curl gnupg \
    && rm -rf /var/lib/apt/lists/* \
    && curl -fsSL -o /tmp/swift.tar.gz "$SWIFT_URL" \
    && curl -fsSL -o /tmp/swift.tar.gz.sig "$SWIFT_URL.sig" \
    && echo "$SWIFT_SHA256  /tmp/swift.tar.gz" | sha256sum -c - \
    && export GNUPGHOME="$(mktemp -d)" \
    && curl -fsSL --compressed https://swift.org/keys/all-keys.asc | gpg --batch --quiet --import \
    && gpg --batch --status-fd 1 --verify /tmp/swift.tar.gz.sig /tmp/swift.tar.gz | grep -q "VALIDSIG .* $SWIFT_KEY_FPR\$" \
    && mkdir /swift-root \
    && tar -xzf /tmp/swift.tar.gz -C /swift-root --strip-components=1 --no-same-owner \
    && chmod -R go-w /swift-root \
    && rm -rf /tmp/swift.tar.gz /tmp/swift.tar.gz.sig "$GNUPGHOME"

# Final image on the canonical ubuntu:24.04 base. The toolchain's runtime packages are the ones
# the official swift:5.10 image installs; the toolchain itself lands in /usr as that image has it.
FROM public.ecr.aws/docker/library/ubuntu:24.04@sha256:0d39fcc8335d6d74d5502f6df2d30119ff4790ebbb60b364818d5112d9e3e932

RUN apt-get update \
    && DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends \
        asciinema \
        binutils \
        ca-certificates \
        git \
        gnupg2 \
        libc6-dev \
        libcurl4-openssl-dev \
        libedit2 \
        libgcc-13-dev \
        libncurses-dev \
        libpython3-dev \
        libsqlite3-0 \
        libstdc++-13-dev \
        libxml2-dev \
        libz3-dev \
        pkg-config \
        tzdata \
        unzip \
        zlib1g-dev \
        tmux \
    && rm -rf /var/lib/apt/lists/*
COPY --from=swift_fetch /swift-root/usr/ /usr/

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
