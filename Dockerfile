# --- Stage 1: The Builder ---
FROM rust:bookworm as builder

ARG EXTRA_FEATURES=""
ARG VERSION_FEATURE_SET="v1"

# Combine RUN layers and clean up apt cache to reduce image size
RUN apt-get update \
    && apt-get install -y --no-install-recommends libpq-dev libssl-dev pkg-config protobuf-compiler \
    && rm -rf /var/lib/apt/lists/* # <-- CHANGE: Clean up apt cache

WORKDIR /router

# Set CI environment variables
ENV CARGO_INCREMENTAL=0
ENV CARGO_NET_RETRY=10
ENV RUSTUP_MAX_RETRIES=10
ENV RUST_BACKTRACE="short"

# <-- CHANGE: Optimize layer caching for dependencies -->
# Copy only dependency manifests
COPY Cargo.toml Cargo.lock ./
# If you have a .cargo/config.toml, copy it as well
# COPY .cargo .cargo

# Build only the dependencies to create a cached layer
RUN mkdir src && echo "fn main() {println!(\"if you see this, the build broke\")}" > src/main.rs
RUN cargo build --release --locked

# Now, copy the full source code
COPY . .

# Finally, build the actual application, which will be much faster
# as dependencies are already built and cached.
RUN cargo build --release --locked \ # <-- CHANGE: Build in release mode
    -j 1 \ # The -j flag is less critical for a cached build, but fine to keep
    --no-default-features \
    --features ${VERSION_FEATURE_SET} \
    ${EXTRA_FEATURES}


# --- Stage 2: The Runner ---
FROM debian:bookworm-slim # <-- CHANGE: Use a smaller base image

# Placing config and binary executable in different directories
ARG CONFIG_DIR=/local/config
ARG BIN_DIR=/local/bin

# Copy this required fields config file
COPY --from=builder /router/config/payment_required_fields_v2.toml ${CONFIG_DIR}/payment_required_fields_v2.toml

# RUN_ENV decides the corresponding config file to be used
ARG RUN_ENV=sandbox

# args for deciding the executable to export
ARG BINARY=router
ARG SCHEDULER_FLOW=consumer

# <-- CHANGE: Combine RUN layers, use runtime libs, and clean up -->
RUN apt-get update \
    && apt-get install -y --no-install-recommends ca-certificates tzdata libpq5 curl procps \
    && rm -rf /var/lib/apt/lists/*

EXPOSE 8080

ENV TZ=Etc/UTC \
    RUN_ENV=${RUN_ENV} \
    CONFIG_DIR=${CONFIG_DIR} \
    SCHEDULER_FLOW=${SCHEDULER_FLOW} \
    BINARY=${BINARY} \
    RUST_MIN_STACK=4194304

RUN mkdir -p ${BIN_DIR}

# <-- CHANGE: Copy the optimized RELEASE binary -->
COPY --from=builder /router/target/release/${BINARY} ${BIN_DIR}/${BINARY}

# Create the 'app' user and group
RUN useradd --user-group --system --no-create-home --no-log-init app
USER app:app

WORKDIR ${BIN_DIR}

CMD ./${BINARY}
