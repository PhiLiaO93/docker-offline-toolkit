#!/bin/sh
# Run as root on a disposable, already-installed test host.
# Temporarily replace docker.service with a symlink and always restore it.
set -eu
PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
export PATH
test_root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd -P)
unit=/etc/systemd/system/docker.service
[ "$(id -u)" -eq 0 ] || exit 1
[ -f "$unit" ] && [ ! -L "$unit" ] || exit 1
cmp "$unit" "$test_root/systemd/docker.service"
systemctl is-active --quiet docker.service
test_dir=$(mktemp -d /etc/systemd/system/.docker-offline-test.XXXXXX)

restore_unit() {
    if [ -f "$test_dir/original" ]; then
        mv -Tf "$test_dir/original" "$unit"
        systemctl daemon-reload
    fi
    rm -f -- "$test_dir/output"
    rmdir "$test_dir"
}
trap restore_unit EXIT
trap 'exit 130' INT
trap 'exit 143' TERM HUP

mv "$unit" "$test_dir/original"
ln -s "$test_dir/original" "$unit"
systemctl daemon-reload
if sh "$test_root/uninstall.sh" --yes >"$test_dir/output" 2>&1; then
    cat "$test_dir/output"
    printf '%s\n' 'FAIL: replaced service unit was not rejected'
    exit 1
fi
cat "$test_dir/output"
[ -L "$unit" ]
[ -f /usr/local/lib/docker-offline/MANAGED-BY ]
systemctl is-active --quiet docker.service
printf '%s\n' 'PASS: replaced service unit rejected before stopping Docker'
