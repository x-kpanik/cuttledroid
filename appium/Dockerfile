# Optional Appium overlay for the cuttlefish runtime images.
#
# The base images ship no Appium — this overlay adds Node.js 20, the Appium
# server and the UIAutomator2 driver on top of either architecture's image.
#
# Build:
#   ARM64:  docker build -t cuttlefish-appium:latest appium/
#   x86_64: docker build --build-arg BASE_IMAGE=cuttlefish-x86:latest \
#             -t cuttlefish-appium-x86:latest appium/
#
# Use with the regular launchers via IMAGE_NAME:
#   IMAGE_NAME=cuttlefish-appium:latest ./scripts/run-cuttlefish-gpu-arm64.sh 1
#   IMAGE_NAME=cuttlefish-appium-x86:latest ./scripts/run-cuttlefish-gpu-x86.sh 1
#
# See appium/README.md for starting the server inside a running container.

ARG BASE_IMAGE=cuttlefish-ubuntu24:latest
FROM ${BASE_IMAGE}

USER root

# Node.js 20 (for Appium)
RUN curl -fsSL https://deb.nodesource.com/setup_20.x | bash - \
    && apt-get install -y nodejs \
    && rm -rf /var/lib/apt/lists/*

# Appium server
RUN npm install -g appium@latest

# The x86 base image sets HOME=/home/ubuntu, so npm running as root leaves
# root-owned cache files there, which breaks the driver install below with
# EACCES — clean the stray cache (separate layer to keep the npm layer cached)
RUN rm -rf /home/ubuntu/.npm

# Driver installs under ~/.appium, so install it as the ubuntu user.
# Retry: npm fetches inside the driver install occasionally stall.
USER ubuntu
RUN for i in 1 2 3; do \
      appium driver install uiautomator2 && break || { echo "retry $i"; sleep 5; }; \
    done \
    && appium driver list --installed 2>&1 | grep -q uiautomator2

# Appium ports (instance N -> 4722+N)
EXPOSE 4723-4736

# Match the ARM64 base image default user; the x86 launchers pass --user root
# explicitly, so they work with this overlay too
USER ubuntu
