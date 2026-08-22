# Cloud Agent base image for the Pixir Harness.
#
# Pins the exact toolchain CI uses (Erlang/OTP 29, Elixir 1.20.2) plus the
# Node.js 22 + Google Chrome stack the experimental `monitor/` sibling app's
# browser suites need. Precompiled OTP/Elixir come from builds.hex.pm, the same
# source erlef/setup-beam uses in CI, so no source compilation is required.
#
# Stable system dependencies live here; repository-dependent work (deps.get,
# compile, escript build) lives in the idempotent install script.
FROM ubuntu:24.04

ENV DEBIAN_FRONTEND=noninteractive \
    LANG=en_US.UTF-8 \
    LANGUAGE=en_US:en \
    LC_ALL=en_US.UTF-8

# Toolchain versions, pinned for reproducibility.
ARG OTP_VERSION=29.0.5
ARG ELIXIR_VERSION=1.20.2
ARG ELIXIR_OTP_MAJOR=29
ARG NODE_VERSION=22.14.0

# System packages: git/curl for source install, OTP runtime libraries
# (libssl/libncurses), build-essential for any dependency that compiles native
# code, unzip for the Elixir archive, and locales for a UTF-8 environment.
RUN apt-get update \
    && apt-get install -y --no-install-recommends \
        ca-certificates \
        curl \
        git \
        unzip \
        xz-utils \
        locales \
        build-essential \
        libssl3t64 \
        libncurses6 \
        libncursesw6 \
    && sed -i 's/^# *\(en_US.UTF-8\)/\1/' /etc/locale.gen \
    && locale-gen en_US.UTF-8 \
    && rm -rf /var/lib/apt/lists/*

# Erlang/OTP (precompiled for ubuntu-24.04).
RUN curl -fsSL -o /tmp/otp.tar.gz \
        "https://builds.hex.pm/builds/otp/ubuntu-24.04/OTP-${OTP_VERSION}.tar.gz" \
    && mkdir -p /opt/otp \
    && tar -xzf /tmp/otp.tar.gz -C /opt/otp --strip-components=1 \
    && rm /tmp/otp.tar.gz \
    && ( cd /opt/otp && ./Install -minimal /opt/otp ) \
    && for b in erl erlc epmd escript run_erl to_erl dialyzer typer ct_run erl_call; do \
        ln -sf "/opt/otp/bin/$b" "/usr/local/bin/$b"; \
    done

# Elixir (precompiled against the matching OTP major).
RUN curl -fsSL -o /tmp/elixir.zip \
        "https://builds.hex.pm/builds/elixir/v${ELIXIR_VERSION}-otp-${ELIXIR_OTP_MAJOR}.zip" \
    && mkdir -p /opt/elixir \
    && unzip -q /tmp/elixir.zip -d /opt/elixir \
    && rm /tmp/elixir.zip \
    && for b in elixir elixirc iex mix; do \
        ln -sf "/opt/elixir/bin/$b" "/usr/local/bin/$b"; \
    done

# Node.js 22 (official prebuilt binary) for the Pixir Monitor browser suites.
RUN curl -fsSL -o /tmp/node.tar.xz \
        "https://nodejs.org/dist/v${NODE_VERSION}/node-v${NODE_VERSION}-linux-x64.tar.xz" \
    && mkdir -p /opt/node \
    && tar -xJf /tmp/node.tar.xz -C /opt/node --strip-components=1 \
    && rm /tmp/node.tar.xz \
    && for b in node npm npx; do \
        ln -sf "/opt/node/bin/$b" "/usr/local/bin/$b"; \
    done

# Google Chrome stable for the Pixir Monitor browser/accessibility gauntlets.
RUN curl -fsSL -o /tmp/chrome.deb \
        "https://dl.google.com/linux/direct/google-chrome-stable_current_amd64.deb" \
    && apt-get update \
    && apt-get install -y --no-install-recommends /tmp/chrome.deb \
    && rm /tmp/chrome.deb \
    && rm -rf /var/lib/apt/lists/*

# Point the Monitor browser suites at Chrome. --no-sandbox is required inside the
# containerized Cloud Agent VM; --disable-dev-shm-usage avoids /dev/shm limits.
ENV PIXIR_MONITOR_BROWSER_BIN=/opt/google/chrome/chrome \
    PIXIR_MONITOR_BROWSER_EXTRA_ARGS="--no-sandbox --disable-dev-shm-usage"

# Run as the non-root user that ships with the Ubuntu base image.
USER ubuntu
