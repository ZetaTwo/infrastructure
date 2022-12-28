#!/bin/sh
mkdir .ssh
chmod 700 .ssh
touch .ssh/authorized_keys
chmod 600 .ssh/authorized_keys
echo "[SSH KEY]" > .ssh/authorized_keys
echo "zetatwo ALL=(ALL:ALL) NOPASSWD: ALL" | tee /etc/sudoers.d/zetatwo
