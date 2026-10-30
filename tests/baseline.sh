# shellcheck shell=bash
# Shared by tests/killsweep.sh and tests/mutants.sh: the kinds of kill-sweep case, and the
# kind of a case id (install-3, xdg-then-uninstall-2, write-manifest.json). No side effects:
# safe to source anywhere.
SWEEP_KINDS=(install upgrade base uninstall keep xdg then-uninstall write)
kind_of() { case $1 in *-then-uninstall-*) echo then-uninstall ;; write-*) echo write ;; *) echo "${1%-*}" ;; esac; }
