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

# Base image: the same swift:5.10-jammy toolchain as the agent's image. Swift has no canonical
# Terminal-Bench base, and the grader has to build with the compiler the agent had.
FROM swift@sha256:ffc42e399ad0cad324f68d58f65e4d5f2c22eb9df73c4dfa249e898d497254b3

ENV LANG=C.UTF-8 \
    LC_ALL=C.UTF-8 \
    PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin

# The image's own Python 3.10 runs pytest and the camera head. Verifier tooling from a
# hash-pinned lockfile; nothing is installed at trial time.
RUN apt-get update \
    && apt-get install -y --no-install-recommends python3-pip \
    && rm -rf /var/lib/apt/lists/*
COPY requirements.txt /tmp/requirements.txt
RUN python3 -m pip install --no-cache-dir --require-hashes --no-deps -r /tmp/requirements.txt && rm -f /tmp/requirements.txt

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
