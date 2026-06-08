# ================================
# Build image
# ================================
ARG SWIFT_VERSION=6.3.0
FROM swift:${SWIFT_VERSION}-noble AS build
ARG WGRIB2_VERSION=3.8.0
ARG NCEPLIBS_G2C_VERSION=2.3.0

# Install OS updates
RUN export DEBIAN_FRONTEND=noninteractive DEBCONF_NONINTERACTIVE_SEEN=true \
    && apt-get -q update \
    && apt-get -q dist-upgrade -y \
    && apt-get install -y \
      ca-certificates \
      build-essential \
      cmake \
      curl \
      libaec-dev \
      libjemalloc-dev \
      libopenjp2-7-dev \
      libpng-dev \
      zlib1g-dev

# Build and install the GRIB2 utilities used by Storm Setup.
RUN set -eux; \
    mkdir -p /tmp/wgrib2-build /tmp/nceplibs-g2c-src /tmp/wgrib2-src; \
    curl -fsSL "https://github.com/NOAA-EMC/NCEPLIBS-g2c/archive/refs/tags/v${NCEPLIBS_G2C_VERSION}.tar.gz" -o /tmp/nceplibs-g2c.tar.gz; \
    tar -xzf /tmp/nceplibs-g2c.tar.gz -C /tmp/nceplibs-g2c-src --strip-components=1; \
    cmake -S /tmp/nceplibs-g2c-src -B /tmp/nceplibs-g2c-src/build \
      -DCMAKE_INSTALL_PREFIX=/usr/local/NCEPLIBS-g2c \
      -DBUILD_SHARED_LIBS=ON \
      -DBUILD_STATIC_LIBS=OFF \
      -DUSE_AEC=ON \
      -DUSE_Jasper=OFF \
      -DUSE_OpenJPEG=ON; \
    cmake --build /tmp/nceplibs-g2c-src/build --parallel "$(nproc)"; \
    cmake --install /tmp/nceplibs-g2c-src/build; \
    curl -fsSL "https://github.com/NOAA-EMC/wgrib2/archive/refs/tags/v${WGRIB2_VERSION}.tar.gz" -o /tmp/wgrib2.tar.gz; \
    tar -xzf /tmp/wgrib2.tar.gz -C /tmp/wgrib2-src --strip-components=1; \
    cmake -S /tmp/wgrib2-src -B /tmp/wgrib2-src/build \
      -DCMAKE_INSTALL_PREFIX=/usr/local \
      -DCMAKE_PREFIX_PATH=/usr/local/NCEPLIBS-g2c \
      -DCMAKE_INSTALL_RPATH=/usr/local/NCEPLIBS-g2c/lib \
      -DBUILD_LIB=OFF \
      -DBUILD_SHARED_LIB=OFF \
      -DUSE_G2CLIB_LOW=ON; \
    cmake --build /tmp/wgrib2-src/build --parallel "$(nproc)"; \
    cmake --install /tmp/wgrib2-src/build; \
    test -x /usr/local/bin/wgrib2

# Set up a build area
WORKDIR /build

# First just resolve dependencies.
# This creates a cached layer that can be reused
# as long as your Package.swift/Package.resolved
# files do not change.
COPY ./Package.* ./
RUN swift package resolve \
        $([ -f ./Package.resolved ] && echo "--force-resolved-versions" || true)

# Copy entire repo into container
COPY . .

RUN mkdir /staging

# Build the application, with optimizations, with static linking, and using jemalloc
# N.B.: The static version of jemalloc is incompatible with the static Swift runtime.
RUN --mount=type=cache,target=/build/.build \
    swift build -c release \
        --static-swift-stdlib \
        -Xlinker -ljemalloc && \
    BIN_PATH="$(swift build -c release --show-bin-path)" && \
    # Copy executables to staging area
    cp "${BIN_PATH}/Run" /staging && \
    cp "${BIN_PATH}/RunWorker" /staging && \
    # Copy resources bundled by SPM to staging area
    find -L "${BIN_PATH}" -regex '.*\.resources$' -exec cp -Ra {} /staging \;


# Switch to the staging area
WORKDIR /staging

# Copy static swift backtracer binary to staging area
RUN cp "/usr/libexec/swift/linux/swift-backtrace-static" ./

# Copy any resources from the public directory and views directory if the directories exist
# Ensure that by default, neither the directory nor any of its contents are writable.
RUN [ -d /build/Public ] && { mv /build/Public ./Public && chmod -R a-w ./Public; } || true
RUN [ -d /build/Resources ] && { mv /build/Resources ./Resources && chmod -R a-w ./Resources; } || true

# ================================
# Run image
# ================================
FROM ubuntu:noble

# Make sure all system packages are up to date, and install only essential packages.
RUN export DEBIAN_FRONTEND=noninteractive DEBCONF_NONINTERACTIVE_SEEN=true \
    && apt-get -q update \
    && apt-get -q dist-upgrade -y \
    && apt-get -q install -y \
      libjemalloc2 \
      ca-certificates \
      libaec0 \
      libopenjp2-7 \
      libpng16-16 \
      tzdata \
# If your app or its dependencies import FoundationNetworking, also install `libcurl4`.
      # libcurl4 \
# If your app or its dependencies import FoundationXML, also install `libxml2`.
      # libxml2 \
    && rm -r /var/lib/apt/lists/*

# Create a vapor user and group with /app as its home directory
RUN useradd --user-group --create-home --system --skel /dev/null --home-dir /app vapor

# Switch to the new home directory
WORKDIR /app

# Copy built executable and any staged resources from builder
COPY --from=build --chown=vapor:vapor /staging /app
COPY --from=build /usr/local/bin/wgrib2 /usr/local/bin/wgrib2
COPY --from=build /usr/local/NCEPLIBS-g2c/lib/libg2c.so* /usr/local/NCEPLIBS-g2c/lib/

# Prepare a writable cache root for Storm Setup while keeping the vapor user model intact.
RUN mkdir -p /app/storage/storm-setup \
    && chown -R vapor:vapor /app/storage

# Provide configuration needed by the built-in crash reporter and some sensible default behaviors.
ENV SWIFT_BACKTRACE=enable=yes,sanitize=yes,threads=all,images=all,interactive=no,swift-backtrace=./swift-backtrace-static

# Ensure all further commands run as the vapor user
USER vapor:vapor

# Let Docker bind to ports used by API and worker health endpoints
EXPOSE 8080
EXPOSE 8081

# Default to the API executable.
CMD ["./Run", "serve", "--env", "production", "--hostname", "0.0.0.0", "--port", "8080"]
