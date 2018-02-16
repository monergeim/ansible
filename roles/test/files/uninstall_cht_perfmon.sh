#!/bin/bash

echo "** Uninstalling CHT Performance Agent ..."


echo "** ensuring $PATH contains sbin folders"
export PATH=$PATH:/usr/local/sbin:/usr/sbin:/sbin
echo "** PATH = "$PATH

AGENT_USER=${1:-none} # do-not-modify-agent-user

command_exists () {
  command -v "$1" >/dev/null 2>&1
}

/etc/init.d/cht_perfmon stop
/etc/init.d/chtcollectd stop

if command_exists rpm ; then
  rpm -e agent
  rpm -e cloudhealth-agent
  rpm -e chtcollectd
else
  dpkg -r agent
  dpkg -r cloudhealth-agent
  dpkg -r chtcollectd
fi  

if command_exists update-rc ; then
  update-rc.d -f cht_perfmon remove
  update-rc.d -f chtcollectd remove
elif command_exists chkconfig ; then
  chkconfig --del cht_perfmon 
  chkconfig --del chtcollectd 
fi


echo "** Removing cht_perfmon ..."
rm -rf /opt/cht_perfmon
rm -f /etc/init.d/cht_perfmon
rm -rf /etc/cht_perfmon
rm -f /etc/cron.daily/cht_refresh_collectd
rm -f /etc/sudoers.d/cht_agent

if test $AGENT_USER != "do-not-modify-agent-user"; then
  userdel -r cht_agent
fi

echo "** Removing chtcollectd ..."
rm -rf /var/lib/chtcollectd
rm -rf /opt/chtcollectd
rm -rf /etc/chtcollectd
rm -f /etc/init.d/chtcollectd
rm -f /etc/cron.daily/cht_refresh_chtcollectd

echo "** Removing collectd if it was installed by cht_agent ..."
if [ -d /var/lib/chtcollectd ] ; then
  COLLECTD_GROUP=$(stat -c "%G" /var/lib/chtcollectd)
  if test $COLLECTD_GROUP = "cht_agent" ; then
    /etc/init.d/chtcollectd stop

    if command_exists update-rc ; then
      update-rc.d -f chtcollectd remove
    elif command_exists chkconfig ; then
      chkconfig --del chtcollectd
    fi

    if command_exists apt-get ; then
      apt-get remove chtcollectd -y
      apt-get remove --purge chtcollectd -y
      apt-get autoremove chtcollectd -y
    elif command_exists yum ; then
      yum remove chtcollectd -y
    fi
  fi
fi

echo "** Finished uninstall."
