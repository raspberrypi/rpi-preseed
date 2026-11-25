# shellcheck shell=dash
# The paths file against the appliers it describes.
#
# An image build persists what the file lists and nothing else, so a write the
# file omits is a setting lost at the first reboot, and nothing on the device
# says so. Four checks hold the two together: the file parses, it accounts for
# every key of the schema, every literal path an applier names is declared for
# its domain, and nothing a full apply changes in a sandbox falls outside the
# list.

# _tp_uncovered PATHS — print each target path on stdin no entry covers.
_tp_uncovered() {
    awk -v paths="$1" '
        function under(p, e) { return p == e || index(p, e "/") == 1 }
        BEGIN {
            while ((getline line < paths) > 0) {
                n = split(line, f, " ")
                if (n != 3 || f[1] ~ /^#/) continue
                kind[++c] = f[2]; path[c] = f[3]
            }
        }
        {
            p = $0; want = ""; ok = 0
            if (p ~ /^\/boot\/firmware\//) { want = "boot"; sub(/^\/boot\/firmware\//, "", p) }
            else if (p ~ /^\/home\/[^\/]+\//) { want = "home"; sub(/^\/home\/[^\/]+\//, "", p) }
            for (i = 1; i <= c && !ok; i++) {
                if (want != "") ok = (kind[i] == want && under(p, path[i]))
                else if (kind[i] == "file") ok = (p == path[i])
                else if (kind[i] == "dir") ok = under(p, path[i])
            }
            if (!ok) print $0
        }'
}

# _tp_undeclared PATHS — stdin is "domains|path" for each literal an applier
# passes to target_path; print those its domains do not declare. A literal
# may be only the directory of what is written, the name being added later.
_tp_undeclared() {
    awk -F'|' -v paths="$1" '
        function under(p, e) { return p == e || index(p, e "/") == 1 }
        BEGIN {
            while ((getline line < paths) > 0) {
                n = split(line, f, " ")
                if (n != 3 || f[1] ~ /^#/) continue
                sub(/\..*/, "", f[1])
                dom[++c] = f[1]; kind[c] = f[2]; path[c] = f[3]
            }
            # Read or probed, never written.
            n = split("/etc /etc/skel /etc/nsswitch.conf /usr/bin /usr/share/zoneinfo", r, " ")
            for (i = 1; i <= n; i++) reads[r[i]] = 1
        }
        {
            p = $2; ok = 0
            if (p in reads) next
            want = ""
            if (p ~ /^\/boot\//) { want = "boot"; sub(/^\/boot\/(firmware\/)?/, "", p) }
            for (i = 1; i <= c && !ok; i++) {
                if (index(" " $1 " ", " " dom[i] " ") == 0) continue
                if (want != "") ok = (kind[i] == want && p == path[i])
                else if (kind[i] == "dir") ok = under(p, path[i])
                else if (kind[i] == "file") ok = under(path[i], p)
            }
            if (!ok) print $1 ": " $2
        }'
}

t_paths() {
    _tp_paths=${RPI_PRESEED_PATHS:-$REPO/schema/paths}
    assert_file "paths file present" "$_tp_paths"

    _tp_bad=$(awk '
        /^[[:space:]]*(#|$)/ { next }
        NF != 3                                   { print; next }
        $2 == "file" || $2 == "dir"               { if ($3 !~ /^\/[^\/]/) print; next }
        $2 == "boot" || $2 == "home"              { if ($3 ~ /^[\/-]/) print; next }
        $2 == "action"                            { if ($3 != "-") print; next }
        { print }' "$_tp_paths")
    assert_eq "every paths line is well formed" "$_tp_bad" ""

    # A new key has to say what it writes, even if that is "action". A line
    # naming only a section speaks for all of its keys.
    _tp_keys=$(awk '/^[a-z]/ && $1 ~ /\./ { sub(/\.\*/, "", $1); print $1 }' "$RPI_PRESEED_SCHEMA" | sort -u)
    _tp_entries=$(awk '/^[a-z]/ && $1 != "core" { print $1 }' "$_tp_paths" | sort -u)
    assert_eq "every schema key is declared" "$(printf '%s\n' "$_tp_keys" | while IFS= read -r _tp_k; do
            printf '%s\n' "$_tp_entries" | grep -qxF -e "$_tp_k" -e "${_tp_k%%.*}" || echo "$_tp_k"
        done)" ""
    assert_eq "every paths entry is a schema key or section" "$(printf '%s\n' "$_tp_entries" | while IFS= read -r _tp_k; do
            printf '%s\n' "$_tp_keys" | sed 's/\..*//' | grep -qxF "$_tp_k" && continue
            printf '%s\n' "$_tp_keys" | grep -qxF "$_tp_k" || echo "$_tp_k"
        done)" ""
    assert_eq "sections declared whole are the expected ones" \
        "$(printf '%s\n' "$_tp_entries" | grep -v '\.' | paste -sd' ' -)" "packages runcmd users"

    _tp_missing=$(for _tp_f in "$RPI_PRESEED_SRCDIR"/apply/*.sh; do
        _tp_d=$(basename "$_tp_f" .sh)
        case "$_tp_d" in
            certs) _tp_d=ca_certificates ;;
            user)  _tp_d="user users" ;;
            ssh)   _tp_d="ssh users" ;;
        esac
        grep -o 'target_path "\{0,1\}/[^ ")]*' "$_tp_f" | sed 's/^target_path "\{0,1\}//' |
            while IFS= read -r _tp_l; do
                _tp_p=${_tp_l%%\$*}
                printf '%s|%s\n' "$_tp_d" "${_tp_p%/}"
            done
    done | sort -u | _tp_undeclared "$_tp_paths")
    assert_eq "every path an applier names is declared" "$_tp_missing" ""

    # The example config sets something in every section.
    _tp_r=$(mktemp -d)
    mkdir -p "$_tp_r/etc" "$_tp_r/boot/firmware" "$_tp_r/home/pi" "$_tp_r/usr/lib/systemd/user"
    echo "pi:x:1000:1000:,,,:/home/pi:/bin/bash" >"$_tp_r/etc/passwd"
    echo "pi:!:19000:0:99999:7:::" >"$_tp_r/etc/shadow"
    printf 'pi:x:1000:\nsudo:x:27:\ngpio:x:993:\n' >"$_tp_r/etc/group"
    printf '127.0.0.1\tlocalhost\n127.0.1.1\traspberrypi\n' >"$_tp_r/etc/hosts"
    echo "console=tty1 rootwait" >"$_tp_r/boot/firmware/cmdline.txt"
    echo "# config" >"$_tp_r/boot/firmware/config.txt"
    echo "cert" >"$_tp_r/boot/firmware/corp-root-ca.crt"
    for _tp_u in rpi-connect.service rpi-connect-wayvnc.service rpi-connect-signin.path; do
        : >"$_tp_r/usr/lib/systemd/user/$_tp_u"
    done
    sed -e 's/^passwordless_sudo = false/passwordless_sudo = true/' \
        -e 's/^spi = false/spi = true/' \
        "$REPO/examples/rpi-preseed.toml" >"$_tp_r/boot/firmware/rpi-preseed.toml"

    _tp_snap() {
        ( cd "$_tp_r" && { find . -type f -exec sha256sum {} +; find . -type l -printf 'link  %p\n'; } | LC_ALL=C sort )
    }
    _tp_snap >"$_tp_r.before"
    env -u RPI_PRESEED_STATE_DIR -u RPI_PRESEED_BOOT_DIR RPI_PRESEED_ROOT="$_tp_r" \
        sh "$RPI_PRESEED_SRCDIR/rpi-preseed" apply --phase base >/dev/null 2>&1
    _tp_snap >"$_tp_r.after"
    _tp_changed=$(LC_ALL=C comm -13 "$_tp_r.before" "$_tp_r.after" | sed 's/^[^ ]*  \.//')

    # Guards the check itself: a run that applied nothing would pass it.
    for _tp_want in /etc/hostname /home/alice/.ssh/authorized_keys /boot/firmware/cmdline.txt \
                    /etc/sudoers.d/010_rpi-preseed-nopasswd /var/lib/systemd/linger/alice; do
        assert_contains "full apply wrote $_tp_want" "$_tp_changed" "$_tp_want"
    done
    assert_eq "everything a full apply writes is declared" \
        "$(printf '%s\n' "$_tp_changed" | _tp_uncovered "$_tp_paths")" ""
    rm -rf "$_tp_r" "$_tp_r.before" "$_tp_r.after"
}
