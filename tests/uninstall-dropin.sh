#!/bin/sh
# Run as root on a disposable, already-installed test host.
# Adds a temporary docker.service-specific drop-in and always removes it.
set -eu
PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
export PATH
test_root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd -P)
dropin_dir=/etc/systemd/system/docker.service.d
dropin_file=$dropin_dir/99-docker-offline-test.conf
[ "$(id -u)" -eq 0 ] || exit 1
[ ! -e "$dropin_file" ] || exit 1
systemctl is-active --quiet docker.service
mkdir -p "$dropin_dir"

cleanup() {
    rm -f -- "$dropin_file"
    rmdir "$dropin_dir" 2>/dev/null || true
    systemctl daemon-reload
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM HUP

cat >"$dropin_file" <<EOF
[Service]
Environment=DOCKER_OFFLINE_DROPIN_TEST=1
EOF
systemctl daemon-reload
if sh "$test_root/uninstall.sh" --yes >"$dropin_dir/test-output" 2>&1; then
    cat "$dropin_dir/test-output"
    rm -f -- "$dropin_dir/test-output"
    printf '%s\n' 'FAIL: service-specific drop-in was not rejected'
    exit 1
fi
cat "$dropin_dir/test-output"
rm -f -- "$dropin_dir/test-output"
[ -f /usr/local/lib/docker-offline/MANAGED-BY ]
systemctl is-active --quiet docker.service
printf '%s\n' 'PASS: service-specific drop-in rejected before stopping Docker'
