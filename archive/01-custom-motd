#!/bin/sh
/usr/bin/screenfetch
NONE='\033[00m'
RED='\033[01;31m'
CYAN='\033[01;36m'
YELLOW='\033[01;33m'
# Displaying System Information
cores=$(grep -c ^processor /proc/cpuinfo 2>/dev/null)
[ "$cores" -eq "0" ] && cores=1
threshold="${cores:-1}.0"
if [ $(echo "`cut -f1 -d ' ' /proc/loadavg` < $threshold" | bc) -eq 1 ]; then
    echo
    echo -n "  System information as of "
    /bin/date
    echo
    /usr/bin/landscape-sysinfo
else
    echo
    echo " System information disabled due to load higher than $threshold"
fi
# displays if updates are needed
stamp="/var/lib/update-notifier/updates-available"
[ ! -r "$stamp" ] || cat "$stamp"
#checking if fsck is needed at reboot
if [ -x /usr/lib/update-notifier/update-motd-fsck-at-reboot ]; then
exec /usr/lib/update-notifier/update-motd-fsck-at-reboot
fi
# if the current release is under development there won't be a new one
if [ "$(lsb_release -sd | cut -d' ' -f4)" = "(development" ]; then
    exit 0
fi
if [ -x /usr/lib/ubuntu-release-upgrader/release-upgrade-motd ]; then
    exec /usr/lib/ubuntu-release-upgrader/release-upgrade-motd
fi
#checking if reboot is needed
if [ -x /usr/lib/update-notifier/update-motd-reboot-required ]; then
exec /usr/lib/update-notifier/update-motd-reboot-required
fi 
