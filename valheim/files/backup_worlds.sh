#!/bin/sh

cd ~/.config/unity3d/IronGate/Valheim
tar zcf ~/worlds_backups/worlds_$(date +%Y-%m-%d_%H-%M).tar.gz worlds
