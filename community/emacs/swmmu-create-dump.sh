#!/bin/sh
# Run inside the configured UML guest; target temacs must never run on host.
set -e
layout=/usr/share/uml-swmmu/emacs-layout
{
    IFS= read -r version
    IFS= read -r exec_directory
} < "$layout"
case "$version" in ''|*[!0-9.]*) echo 'Invalid Emacs version in layout' >&2; exit 1;; esac
case "$exec_directory" in /usr/lib/emacs/"$version"/*) ;; *) echo 'Invalid Emacs execution directory' >&2; exit 1;; esac
export EMACSLOADPATH=/usr/share/emacs/$version/lisp
export EMACSDATA=/usr/share/emacs/$version/etc
cd "$EMACSLOADPATH"
/usr/bin/emacs-"$version" -batch -l loadup --temacs=pdump \
    --bin-dest /usr/bin --eln-dest "$exec_directory/native-lisp"
mkdir -p "$exec_directory"
cp /usr/bin/emacs.pdmp "$exec_directory/.emacs.pdmp.new"
chmod 644 "$exec_directory/.emacs.pdmp.new"
mv -f "$exec_directory/.emacs.pdmp.new" "$exec_directory/emacs.pdmp"
/usr/bin/emacs --batch -Q --eval '(unless (pdumper-stats) (kill-emacs 1))'
