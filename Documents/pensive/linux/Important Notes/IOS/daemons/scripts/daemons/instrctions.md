downlaod the following tweaks
python 3.14.3
openssh
gawk
filza
icleanerpro
powerselector



scp /home/dusk/Documents/pensive/linux/Important\ Notes/IOS/daemons/scripts/daemons/daemonmanager root@192.168.29.75:/var/jb/basebin/
scp /home/dusk/Documents/pensive/linux/Important\ Notes/IOS/daemons/scripts/daemons/daemons.cfg root@192.168.29.75:/var/jb/basebin/daemon.cfg


ssh reboot command
launchctl reboot userspace


to apply the list
/var/jb/basebin/daemonmanager apply

to revert

/var/jb/basebin/daemonmanager reset
