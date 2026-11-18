# Hosts come from the Terraform-generated Ansible inventory.

set working-directory := 'ansible'

# List available recipes
default:
    @just --list

# Reboot nodes one at a time and wait for each to come back (default: all)
[confirm('Reboot the node(s)? [y/N]')]
reboot hosts='all':
    ansible '{{ hosts }}' --forks 1 -m ansible.builtin.reboot

# List versions pinned in the repo that have newer upstream releases (--all: list current ones too)
outdated *args:
    @uv run --quiet --script ../scripts/outdated.py {{ args }}

# Show pending apt upgrades, kernel and reboot state on the nodes (default: all)
node-updates hosts='all':
    @ansible '{{ hosts }}' -m ansible.builtin.shell -a 'echo "kernel: running $(uname -r), newest installed $(ls /boot/vmlinuz-* | sed "s#/boot/vmlinuz-##" | sort -V | tail -1)"; test -f /var/run/reboot-required && echo "reboot required: $(sort -u /var/run/reboot-required.pkgs 2>/dev/null | tr "\n" " ")"; echo "upgradable packages:"; apt list --upgradable 2>/dev/null | tail -n +2' | sed 's/ | CHANGED | rc=0 >>//'

# Show pods in all namespaces, as seen from the first node
pods:
    @ssh root@$(ansible all --list-hosts | sed -n 2p | tr -d ' ') k3s kubectl get pods -A -o wide
