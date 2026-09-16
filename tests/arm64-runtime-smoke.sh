#!/bin/sh
# Run inside an ARM64 test host after Docker installation.
# Requires a statically linked busybox binary; performs no registry access.
set -eu

PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
export PATH

case "$(uname -m)" in
    aarch64|arm64) ;;
    *)
        printf '%s\n' 'ERROR: this smoke test requires an ARM64 host' >&2
        exit 1
        ;;
esac

busybox_path=$(command -v busybox 2>/dev/null || true)
[ -n "$busybox_path" ] || {
    printf '%s\n' 'ERROR: busybox-static is required' >&2
    exit 1
}

test_suffix=$$
image_name=docker-offline-arm64-smoke:test-$test_suffix
network_name=docker-offline-arm64-net-$test_suffix
server_name=docker-offline-arm64-server-$test_suffix
test_dir=$(mktemp -d "${TMPDIR:-/tmp}/docker-offline-arm64.XXXXXX")

cleanup() {
    docker rm -f "$server_name" >/dev/null 2>&1 || true
    docker network rm "$network_name" >/dev/null 2>&1 || true
    docker image rm -f "$image_name" >/dev/null 2>&1 || true
    rm -rf -- "$test_dir"
}
trap cleanup EXIT HUP INT TERM

mkdir -p "$test_dir/rootfs/bin" "$test_dir/rootfs/www"
cp "$busybox_path" "$test_dir/rootfs/bin/busybox"
chmod 0755 "$test_dir/rootfs/bin/busybox"
printf '%s\n' arm64-network-ok >"$test_dir/rootfs/www/index.html"

tar -C "$test_dir/rootfs" -cf - . | docker import - "$image_name" >/dev/null
image_platform=$(docker image inspect --format '{{.Os}}/{{.Architecture}}' "$image_name")
[ "$image_platform" = linux/arm64 ] || {
    printf '%s\n' "ERROR: unexpected image platform: $image_platform" >&2
    exit 1
}

docker network create "$network_name" >/dev/null
docker run -d --name "$server_name" --network "$network_name" \
    "$image_name" /bin/busybox httpd -f -h /www -p 8080 >/dev/null
response=$(docker run --rm --network "$network_name" "$image_name" \
    /bin/busybox wget -qO- "http://$server_name:8080/")
[ "$response" = arm64-network-ok ] || {
    printf '%s\n' "ERROR: unexpected network response: $response" >&2
    exit 1
}

printf '%s\n' "PASS: ARM64 image run and user-defined bridge network ($image_platform)"
