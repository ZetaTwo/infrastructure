# Valheim Ansible Playbook

This Ansible playbook will setup a [Valheim](https://www.valheimgame.com/) game server using [LinuxGSM](https://linuxgsm.com/servers/vhserver/) together with cron jobs to monitor, update and back up the server.

To run the playbook, create a `hosts.yaml` file using the template `hosts.yaml.tpl` and then run the playbook with `ansible-playbook -u <remote_user> -i hosts.yaml valheim.yaml`

## TODO

* Fix SSH restart trigger
* Fix apt update after i386 add
* Allow setting up multiple servers
