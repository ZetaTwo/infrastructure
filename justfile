# Hosts come from the Terraform-generated Ansible inventory.

set working-directory := 'ansible'

# List available recipes
default:
    @just --list

# Reboot nodes one at a time and wait for each to come back (default: all)
[confirm('Reboot the node(s)? [y/N]')]
reboot hosts='all':
    ansible '{{ hosts }}' --forks 1 -m ansible.builtin.reboot

# Show pods in all namespaces, as seen from the first node
pods:
    @ssh root@$(ansible all --list-hosts | sed -n 2p | tr -d ' ') k3s kubectl get pods -A -o wide
