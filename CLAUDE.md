# Notes for Claude

- node1 is manually pinned to kernel `7.0.0-38-generic` through `/etc/default/grub.d/90-pin-kernel.cfg` (on the node, not in this repo), because `7.0.0-42` breaks gosu in containerd pods. At the start of infra work, check https://github.com/ZetaTwo/infrastructure/issues/2. If a newer kernel than `-42` is installed on the node, mention that the pin can be revisited and follow the issue's unpin steps. Remove this note when the issue is closed.
