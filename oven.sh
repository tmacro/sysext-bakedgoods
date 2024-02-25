#!/usr/bin/env bash
set -euxo pipefail

bakery="https://github.com/tmacro/sysext-bakedgoods/releases/latest/download/"
if [ -n "${CUSTOM_BAKERY:-}" ]; then
    bakery="${CUSTOM_BAKERY}"
fi

images=(
    "cilium-0.15.0-1"
    "k3s-1.29.0+k3s1-1"
    "k3s-1.29.1+k3s2-1"
)

archs=(
    "x86-64"
)

streams=()

for image in "${images[@]}"; do
    component="${image%%-*}"
    fullversion="${image#*-}"
    version="${fullversion%-*}"
    release="${version##*+}"
    echo "Creating ${component} sysext for version ${version} and release ${release}"
    for arch in "${archs[@]}"; do
        ARCH="${arch}" "./create_${component}_sysext.sh" "${version}" "${component}"
        mv "${component}.raw" "${image}-${arch}.raw"
    done
    streams+=("${component}:-@v")
done

for stream in "${streams[@]}"; do
    component="${stream%:*}"
    pattern="${stream#*:}"
    cat <<-EOF > "${component}.conf"
[Transfer]
Verify=false
[Source]
Type=url-file
Path=${bakery}
MatchPattern=${component}${pattern}-%a.raw
[Target]
InstancesMax=3
Type=regular-file
Path=/opt/extensions/${component%-*}
CurrentSymlink=/etc/extensions/${component%-*}.raw
EOF
done

sha256sum *.raw > SHA256SUMS
