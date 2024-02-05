#!/usr/bin/env bash
set -xeuo pipefail

export ARCH="${ARCH-x86-64}"
SCRIPTFOLDER="$(dirname "$(readlink -f "$0")")"

if [ $# -lt 2 ] || [ "$1" = "-h" ] || [ "$1" = "--help" ]; then
  echo "Usage: $0 VERSION SYSEXTNAME [CNI_VERSION]"
  echo "The script will download the K3S release binaries (e.g., for v1.27.3) and create a sysext squashfs image with the name SYSEXTNAME.raw in the current folder."
  echo "A temporary directory named SYSEXTNAME in the current folder will be created and deleted again."
  echo "All files in the sysext image will be owned by root."
  echo "To use arm64 pass 'ARCH=arm64' as environment variable (current value is '${ARCH}')."
  "${SCRIPTFOLDER}"/bake.sh --help
  exit 1
fi

VERSION="$1"
SYSEXTNAME="$2"
CNI_VERSION="${3-latest}"

K3SARCH=""
if [ "${ARCH}" = "arm64" ]; then
  K3SARCH="aarch64"
fi

rm -rf "${SYSEXTNAME}"
mkdir -p "${SYSEXTNAME}"
mkdir -p "${SYSEXTNAME}"/usr/bin

# install k3s binaries.
curl -L -o "${SYSEXTNAME}"/usr/bin/k3s "https://github.com/k3s-io/k3s/releases/download/v${VERSION}/k3s${K3SARCH}"
chmod 0755 "${SYSEXTNAME}"/usr/bin/k3s
ln -s /usr/bin/k3s "${SYSEXTNAME}"/usr/bin/kubectl

curl -L --fail https://github.com/k3s-io/k3s/releases/download/v${VERSION}/sha256sum-amd64.txt | grep 'k3s$' > "${SYSEXTNAME}"/usr/bin/k3s.sha256sum
pushd "${SYSEXTNAME}"/usr/bin 2>/dev/null
sha256sum --check k3s.sha256sum
rm k3s.sha256sum
popd 2>/dev/null

# setup k3s service.
mkdir -p "${SYSEXTNAME}/usr/lib/systemd/system"
cat > "${SYSEXTNAME}/usr/lib/systemd/system/k3s@.service" <<-'EOF'
[Unit]
Description=K3s Lightweight Kubernetes
Documentation=https://k3s.io
Wants=network-online.target
After=network-online.target
Wants=cni-install.service
After=cni-install.service

[Install]
WantedBy=multi-user.target

[Service]
Type=notify
EnvironmentFile=-/etc/default/%N
EnvironmentFile=-/etc/sysconfig/%N
EnvironmentFile=-/etc/systemd/system/k3s@%i.service.env
KillMode=process
Delegate=yes
# Having non-zero Limit*s causes performance problems due to accounting overhead
# in the kernel. We recommend using cgroups to do container-local accounting.
LimitNOFILE=1048576
LimitNPROC=infinity
LimitCORE=infinity
TasksMax=infinity
TimeoutStartSec=0
Restart=always
RestartSec=5s
ExecStartPre=-/sbin/modprobe br_netfilter
ExecStartPre=-/sbin/modprobe overlay
ExecStartPre=/usr/bin/mkdir -p /opt/cni/bin
ExecStartPre=/usr/bin/cp -r /usr/local/bin/cni/. /opt/cni/bin/
ExecStartPre=/usr/bin/mkdir -p /etc/rancher/k3s/config.yaml.d
ExecStartPre=/usr/bin/cp -r /usr/local/share/k3s/%i.yaml /etc/rancher/k3s/config.yaml.d/00-defaults.yaml
ExecStart=/usr/bin/k3s %i
EOF

# dropin to swap to cgroupfs.
mkdir -p "${SYSEXTNAME}/usr/lib/systemd/system/containerd.service.d"
cat > "${SYSEXTNAME}/usr/lib/systemd/system/containerd.service.d/10-cgroupfs.conf" <<-'EOF'
[Service]
Environment=CONTAINERD_CONFIG=/usr/share/containerd/config-cgroupfs.toml
EOF

# default config for k3s server and agent.
mkdir -p "${SYSEXTNAME}/usr/local/share/k3s"
cat > "${SYSEXTNAME}/usr/local/share/k3s/server.yaml" <<-'EOF'
# This file is copied from /usr/local/share/k3s/server.yaml to /etc/rancher/k3s/config.yaml.d/00-defaults.yaml on every start of the k3s service.
# It is intended to be used to set default values for the k3s service.
#
# DO NOT EDIT THIS FILE DIRECTLY!
# Instead, create a file /etc/rancher/k3s/config.yaml.d/01-custom.yaml and set your custom values there.
# The file /etc/rancher/k3s/config.yaml.d/10-custom.yaml will be sourced after this file and can override the values set here.

container-runtime-endpoint: unix:///run/containerd/containerd.sock
data-dir: /var/lib/rancher/k3s
cluster-cidr: 10.200.0.0/16
cluster-dns: 10.201.0.10
cluster-domain: cluster.local
service-cidr: 10.201.0.0/16
service-node-port-range: 30000-32767
EOF

cat > "${SYSEXTNAME}/usr/local/share/k3s/agent.yaml" <<-'EOF'
# This file is copied from /usr/local/share/k3s/agent.yaml to /etc/rancher/k3s/config.yaml.d/00-defaults.yaml on every start of the k3s service.
# It is intended to be used to set default values for the k3s service.
#
# DO NOT EDIT THIS FILE DIRECTLY!
# Instead, create a file /etc/rancher/k3s/config.yaml.d/01-custom.yaml and set your custom values there.
# The file /etc/rancher/k3s/config.yaml.d/10-custom.yaml will be sourced after this file and can override the values set here.

container-runtime-endpoint: unix:///run/containerd/containerd.sock
data-dir: /var/lib/rancher/k3s
EOF

# install CNI.
version="${CNI_VERSION}"
if [[ "${CNI_VERSION}" == "latest" ]]; then
  version=$(curl -fsSL https://api.github.com/repos/containernetworking/plugins/releases/latest | jq -r .tag_name)
  echo "Using latest version: ${version} for CNI plugins"
fi

CNI_ARCH="${ARCH}"
if [ "${ARCH}" = "x86_64" ] || [ "${ARCH}" = "x86-64" ]; then
  CNI_ARCH="amd64"
elif [ "${ARCH}" = "aarch64" ]; then
  CNI_ARCH="arm64"
fi

curl -o cni.tgz -fsSL "https://github.com/containernetworking/plugins/releases/download/${version}/cni-plugins-linux-${CNI_ARCH}-${version}.tgz"
mkdir -p "${SYSEXTNAME}/usr/local/bin/cni"
tar --force-local -xf "cni.tgz" -C "${SYSEXTNAME}/usr/local/bin/cni"
rm -f cni.tgz

mkdir -p "${SYSEXTNAME}/usr/share/cni"
cat > "${SYSEXTNAME}/usr/share/cni/99-loopback.conflist" <<-'EOF'
{
    "cniVersion": "1.0.0",
    "name": "loopback",
    "plugins": [
        {
            "type": "loopback"
        }
    ]
}
EOF

# setup cni install service.
cat > "${SYSEXTNAME}/usr/lib/systemd/system/cni-install.service" <<-'EOF'
[Unit]
Wants=network-online.target
After=network-online.target
ConditionPathExists=!/opt/cni/bin

[Service]
Type=oneshot
ExecStartPre=/usr/bin/mkdir -p /opt/cni/bin
ExecStartPre=/usr/bin/cp -r /usr/local/bin/cni/. /opt/cni/bin/
ExecStartPre=/usr/bin/mkdir -p /etc/cni/net.d
ExecStart=/usr/bin/cp /usr/share/cni/99-loopback.conflist /etc/cni/net.d/99-loopback.conflist
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
EOF

"${SCRIPTFOLDER}"/bake.sh "${SYSEXTNAME}"
rm -rf "${SYSEXTNAME}"