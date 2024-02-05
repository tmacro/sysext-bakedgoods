#!/usr/bin/env bash
set -xeuo pipefail

export ARCH="${ARCH-x86-64}"
SCRIPTFOLDER="$(dirname "$(readlink -f "$0")")"

if [ $# -lt 2 ] || [ "$1" = "-h" ] || [ "$1" = "--help" ]; then
  echo "Usage: $0 VERSION SYSEXTNAME [CILIUM_VERSION]"
  echo "The script will download the Cilium release binaries (e.g., for v1.27.3) and create a sysext squashfs image with the name SYSEXTNAME.raw in the current folder."
  echo "A temporary directory named SYSEXTNAME in the current folder will be created and deleted again."
  echo "All files in the sysext image will be owned by root."
  echo "To use arm64 pass 'ARCH=arm64' as environment variable (current value is '${ARCH}')."
  "${SCRIPTFOLDER}"/bake.sh --help
  exit 1
fi

VERSION="$1"
SYSEXTNAME="$2"

# The github release uses different arch identifiers (not the same as in the other scripts here),
# we map them here and rely on bake.sh to map them back to what systemd expects
if [ "${ARCH}" = "amd64" ] || [ "${ARCH}" = "x86-64" ]; then
  ARCH="amd64"
elif [ "${ARCH}" = "arm64" ]; then
  ARCH="aarch64"
fi

rm -f cilium-linux-${ARCH}.tar.gz{,.sha256sum}
curl -L --fail --remote-name-all https://github.com/cilium/cilium-cli/releases/download/v${VERSION}/cilium-linux-${ARCH}.tar.gz{,.sha256sum}
sha256sum --check cilium-linux-${ARCH}.tar.gz.sha256sum

rm -rf "${SYSEXTNAME}"
mkdir -p "${SYSEXTNAME}"
mkdir -p "${SYSEXTNAME}"/usr/bin

tar --force-local -xf  cilium-linux-${ARCH}.tar.gz -C "${SYSEXTNAME}"/usr/bin/
rm cilium-linux-${ARCH}.tar.gz{,.sha256sum}

mkdir -p "${SYSEXTNAME}/usr/lib/systemd/system"
cat > "${SYSEXTNAME}/usr/lib/systemd/system/cilium-install.service" <<-'EOF'
[Unit]
Description=Cilium
Wants=network-online.target
After=network-online.target

[Service]
Type=oneshot
RemainAfterExit=yes
Environment="CILIUM_VERSION=1.15.0"
EnvironmentFile=-/etc/sysconfig/cilium
ExecStartPre=/usr/bin/cilium install --version $CILIUM_VERSION
ExecStart=/usr/bin/cilium status --wait
StartLimitInterval=0
RestartSec=10

[Install]
WantedBy=multi-user.target
EOF


"${SCRIPTFOLDER}"/bake.sh "${SYSEXTNAME}"
rm -rf "${SYSEXTNAME}"
