# The labelrefinery image: orca (scheduler and UI), Pipeline A over AV2 as an
# orca pipeline, the av2.logs writer, the AV2 slice viewer and LabelControl's
# site, built in Refinery's `orca` pixi environment onto a slim Debian with
# only the libraries they load. arm64, for Graviton. From Refinery's root:
#
#     docker build -f deploy/Dockerfile -t refinery:dev .
#
# The sibling sources compile at the revisions deploy/deps.txt pins, laid out
# as on a workstation (/src/magmalake/*, /src/labelrefinery/*), so pixi.toml's
# DEP_INC paths hold.
FROM ghcr.io/prefix-dev/pixi:0.78.0 AS build
RUN apt-get update && apt-get install -y --no-install-recommends gcc libc6-dev git ca-certificates \
    && rm -rf /var/lib/apt/lists/*
COPY deploy/deps.txt /tmp/deps.txt
RUN grep -v '^#' /tmp/deps.txt | while read -r repo rev path; do \
        git clone -q "https://github.com/$repo" "/src/$path" \
        && git -C "/src/$path" checkout -q "$rev" || exit 1; \
    done
WORKDIR /src/labelrefinery/Refinery
COPY pixi.toml pixi.lock ./
RUN pixi install --locked -e orca
COPY src src
COPY viewer viewer
COPY configs configs
RUN pixi run -e orca sh -c 'mkdir -p /out/bin /out/pipelines \
    && mojo build $DEP_INC ../../magmalake/orca.mojo/bin/scheduler.mojo -o /out/bin/orca \
    && mojo build -I src $DEP_INC src/av2_logs.mojo -o /out/bin/av2-logs \
    && mojo build -I src $DEP_INC src/av2_viewer.mojo -o /out/bin/av2-viewer \
    && mojo build -I ../LabelControl/src $DEP_INC ../LabelControl/src/server.mojo -o /out/bin/labelcontrol \
    && mojo build -I src $DEP_INC src/av2_pipeline_a.mojo -o /out/pipelines/av2-pipeline-a'
# What the binaries link, and what they and their tins dlopen from
# $CONDA_PREFIX/lib (libpq, flare's and objectstore's shims, the codecs,
# sqlite), with what those link: only the pixi environment's libraries.
RUN env=/src/labelrefinery/Refinery/.pixi/envs/orca && mkdir -p /out/lib \
    && loaded=$(ls $env/lib/libpq.so* $env/lib/libflare_*.so $env/lib/libobjectstoremojo.so \
        $env/lib/libzstd.so* $env/lib/liblz4.so* $env/lib/libbrotli*.so* $env/lib/libsnappy.so* \
        $env/lib/libdeflate.so* $env/lib/libz.so* $env/lib/libsqlite3.so* $env/lib/libcurl.so* 2>/dev/null || true) \
    && ldd /out/bin/* /out/pipelines/* $loaded | awk -v e="$env" '$3 ~ "^"e {print $3}' \
        | sort -u | xargs -r cp -L -t /out/lib \
    && cp -L -t /out/lib $loaded

FROM debian:bookworm-slim
# tzdata: orca's schedules read the system's TZif files.
RUN apt-get update && apt-get install -y --no-install-recommends tzdata ca-certificates \
    && rm -rf /var/lib/apt/lists/*
COPY --from=build /out/lib /opt/orca/lib
COPY --from=build /out/bin /opt/orca/bin
COPY --from=build /out/pipelines /opt/orca/pipelines
COPY viewer /opt/refinery/viewer
COPY configs /opt/refinery/configs
# postgres.mojo, flare and objectstore find what they dlopen under
# $CONDA_PREFIX/lib.
ENV CONDA_PREFIX=/opt/orca LD_LIBRARY_PATH=/opt/orca/lib \
    PATH=/opt/orca/bin:/opt/orca/pipelines:/usr/bin:/bin \
    AV2_VIEWER_ASSETS=/opt/refinery/viewer AV2_ROOT=/var/lib/av2
ENTRYPOINT ["/opt/orca/bin/orca"]
