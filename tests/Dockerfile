# Verifier image. Runs in its own container, sees only the paths declared in `artifacts`, and
# holds everything the agent never sees: both recorded passes, the held-back flight catalogue,
# the true attitude of every graded frame and the camera head that replays the passes. It
# builds the collected Swift itself and runs the tracker against camera heads it starts.

# The tracker is started through tests/launch.c, which lets it start no other program. Built
# statically in a throwaway stage, so no C compiler reaches the final image.
FROM public.ecr.aws/docker/library/python:3.13-slim-bookworm@sha256:01f42367a0a94ad4bc17111776fd66e3500c1d87c15bbd6055b7371d39c124fb AS launcher
RUN apt-get update && apt-get install -y --no-install-recommends gcc libc6-dev && rm -rf /var/lib/apt/lists/*
COPY launch.c /tmp/launch.c
RUN gcc -O2 -static -Wall -o /tool_launch /tmp/launch.c

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

# Final image on the canonical ubuntu:24.04 base with the same Swift 5.10.1 toolchain as the
# agent's image, since the grader has to build with the compiler the agent had.
FROM public.ecr.aws/docker/library/ubuntu:24.04@sha256:0d39fcc8335d6d74d5502f6df2d30119ff4790ebbb60b364818d5112d9e3e932

ENV LANG=C.UTF-8 \
    LC_ALL=C.UTF-8 \
    PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin

# The image's own Python 3.12 runs pytest and the camera head. Verifier tooling from a
# hash-pinned lockfile; nothing is installed at trial time.
RUN apt-get update \
    && DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends \
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
        python3-pip \
    && rm -rf /var/lib/apt/lists/*
COPY --from=swift_fetch /swift-root/usr/ /usr/
COPY requirements.txt /tmp/requirements.txt
RUN python3 -m pip install --no-cache-dir --break-system-packages --require-hashes --no-deps -r /tmp/requirements.txt && rm -f /tmp/requirements.txt

# The same toolchain the agent had: no Foundation, Dispatch or XCTest module to import.
RUN rm -rf /usr/lib/swift/linux/x86_64/Foundation*.swift* /usr/lib/swift/linux/x86_64/XCTest.swift* \
           /usr/lib/swift_static/linux/x86_64/Foundation*.swift* \
           /usr/lib/swift_static/linux/libFoundation*.a /usr/lib/swift_static/linux/libCoreFoundation.a \
           /usr/lib/swift_static/linux/libCFURLSessionInterface.a /usr/lib/swift_static/linux/libCFXMLInterface.a \
           /usr/lib/swift/CoreFoundation /usr/lib/swift_static/CoreFoundation \
           /usr/lib/swift/linux/x86_64/Dispatch.swift* /usr/lib/swift_static/linux/x86_64/Dispatch.swift* \
           /usr/lib/swift/dispatch /usr/lib/swift_static/dispatch

COPY --from=launcher /tool_launch /usr/local/bin/tool_launch
RUN useradd --create-home --uid 10001 --shell /bin/bash runner

# Warm the build user's module cache, so the graded build compiles the tracker's own code only.
RUN mkdir -p /tmp/warm && printf 'import Glibc\nprint(sqrt(2.0))\n' > /tmp/warm/main.swift \
    && chown -R runner:runner /tmp/warm \
    && su runner -s /bin/bash -c 'cd /tmp/warm && HOME=/home/runner swiftc -O -static-stdlib -o /tmp/warm/warm main.swift && ./warm' \
    && rm -rf /tmp/warm

# Landing directory for the declared artifact.
RUN mkdir -p /app/tracker && chown -R runner:runner /app && chmod 1755 /app

# The passes, the catalogues, the true attitudes and the camera head. Root only, and never in
# any container the agent reaches.
COPY data /opt/truth
COPY golden /opt/truth/golden
COPY camera /opt/camera
RUN chmod 700 /opt/truth /opt/camera

# Separate mode does not upload tests/ into the image, so the image owns /tests itself.
COPY . /tests/

WORKDIR /app/tracker
