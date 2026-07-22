# shellcheck shell=dash

scenario_fault_pre() {
    qemu_fault_helper_fail "$1" /usr/lib/raspberrypi-sys-mods/imager_custom
}
