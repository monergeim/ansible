#!/usr/bin/env bash

SCRIPTPATH=$( cd $(dirname $0) ; pwd -P)

rm -f /tmp/agent_install_log.txt
echo "** CHT Performance Agent version "$1 2>&1 | tee -a /tmp/agent_install_log.txt
AGENT_VERSION=$1
KEY=$2
CLOUD=$3
PERFMON_ENV=${4:-production}
AGENT_USER=${5:-none} # do-not-modify-agent-user
SUDOER_MOD=${6:-none} # do-not-modify-sudoers

# ensure that the optional proxy settings are specified only if the mandatory ones are present
if [ -z "$PROXY_HOST" ]; then
  PROXY_PORT=
fi
if [ -z "$PROXY_PORT" ]; then
  PROXY_USER=
fi
if [ -z "$PROXY_USER" ]; then
  PROXY_PASSWORD=
fi

abort_agent_install() {
  echo "** Agent install failed! See complete install log at: /tmp/agent_install_log.txt **"

  # delete the lock file if aborting installation
  file="/tmp/agent_install.lock"

  if [ -f $file ] ; then
    rm $file
  fi

  exit 1
}

if [ -z "$CLOUD" ]; then
  echo "Cloud name cannot be empty"
  echo "Key :"$KEY
  echo "Environment :"$PERFMON_ENV
  echo "AGENT_USER :"$AGENT_USER
  echo "SUDOER_MOD :"$SUDOER_MOD
  abort_agent_install
fi

if [ -z "$KEY" ]; then
  echo "KEY name cannot be empty"
  echo "Environment :"$PERFMON_ENV
  echo "AGENT_USER :"$AGENT_USER
  echo "SUDOER_MOD :"$SUDOER_MOD
  abort_agent_install
fi

if test $CLOUD != "vmware" && test $CLOUD != "aws" && test $CLOUD != "datacenter" && test $CLOUD != "azure"; then
  echo $CLOUD" currently not supported" 2>&1 | tee -a /tmp/agent_install_log.txt
  abort_agent_install
fi

if test $CLOUD = "vmware" || test $PERFMON_ENV = "development"; then
  SKIP_COLLECTD=true
else
  SKIP_COLLECTD=false
fi


command_exists () {
  command -v "$1" >/dev/null 2>&1
}

is_perfmon_running () {
  /etc/init.d/cht_perfmon status | grep "cht_perfmon_collector: running" >/dev/null 2>&1
}

remove_dup_processes () {
  all=`ps -ef | grep cht_perfmon | grep -v install_cht_perfmon | awk 'BEGIN {printf "kill -9 "} {printf $2" "}'`
  col=`cat /opt/cht_perfmon/collector.pid`
  mon=`cat /opt/cht_perfmon/monitor.pid`
  echo $all > /tmp/cht_agent_dup.txt
  sed -e "s/$mon//" /tmp/cht_agent_dup.txt > /tmp/cht_agent_dup2.txt
  sed -e "s/$col//" /tmp/cht_agent_dup2.txt > /tmp/cht_agent_dup.txt
  rmdup=`cat /tmp/cht_agent_dup.txt`
  rm /tmp/cht_agent_dup.txt
  rm /tmp/cht_agent_dup2.txt
  $rmdup 2>/dev/null
  echo
}

install_component () {
  # $1 = source file
  # $2 = remote S3 folder
  # $3 = target destination
  if [ ! -f "$SCRIPTPATH/$1" ] ; then
    echo "** Installing "$3" from https://s3.amazonaws.com/remote-collector/agent/"$2/$1 2>&1 | tee -a /tmp/agent_install_log.txt
    if [ -z "$PROXY_HOST" ] ; then
        wget -q "https://s3.amazonaws.com/remote-collector/agent/$2/$1" -O "$3"
    else
        wget -e use_proxy=yes -e https_proxy=$PROXY_HOST:$PROXY_PORT -q "https://s3.amazonaws.com/remote-collector/agent/$2/$1" -O "$3"
    fi
  else
    echo "** Installing "$3" from "$SCRIPTPATH/$1 2>&1 | tee -a /tmp/agent_install_log.txt
    cp "$SCRIPTPATH/$1" "$3"
  fi
}

rm -rf cht_agent_install
mkdir -p cht_agent_install 
cd cht_agent_install

echo "First clearing any previous install" | tee -a /tmp/agent_install_log.txt
install_component "uninstall_cht_perfmon.sh" "." uninstall_cht_perfmon.sh
sh uninstall_cht_perfmon.sh $AGENT_USER | tee -a /tmp/agent_install_log.txt 2>&1 | tee -a /tmp/agent_install_log.txt

echo "** ensuring $PATH contains sbin folders" 2>&1 | tee -a /tmp/agent_install_log.txt
export PATH=$PATH:/usr/local/sbin:/usr/sbin:/sbin
echo "** PATH = "$PATH 2>&1 | tee -a /tmp/agent_install_log.txt

echo "** PERFMON_ENV: "$PERFMON_ENV 2>&1 | tee -a /tmp/agent_install_log.txt
if test $PERFMON_ENV != "development"; then
  if test $AGENT_USER != "do-not-modify-agent-user"; then
    echo "** Creating user cht_agent:cht_agent" 2>&1 | tee -a /tmp/agent_install_log.txt
    # make sure docker group exists so that agent has access if docker
    # is installed or ever gets installed
    if ! egrep -q -i "^docker" /etc/group; then
      groupadd docker
    fi
    useradd cht_agent -m -U -G docker
  else
    echo "** Skipping creation of User cht_agent:cht_agent" 2>&1 | tee -a /tmp/agent_install_log.txt
  fi
fi


if test $SKIP_COLLECTD = true ; then
  echo "** Skipping collectd install."  2>&1 | tee -a /tmp/agent_install_log.txt
  # to ensure unsent files and other temp files hava a consistent place to go
  COLLECTD_CONF_DIR="/dev/null"
else
  rm -rf /var/lib/chtcollectd
  mkdir /var/lib/chtcollectd
  mkdir /etc/chtcollectd/
  chmod -R ugo+rw /var/lib/chtcollectd

  if command_exists yum ; then
    echo "** Installing collectd via yum.."  2>&1 | tee -a /tmp/agent_install_log.txt
    if ! command_exists wget ; then
      echo "** Installing wget first.."  2>&1 | tee -a /tmp/agent_install_log.txt
      yum install wget
    fi
  fi

  echo "** Installing chtcollectd ..."
  if command_exists dpkg ; then
    CHTCOLLECT_PACKAGE="chtcollectd_v"$1".deb"
    PACKAGE_CMD="dpkg"
  elif command_exists rpm ; then
    CHTCOLLECT_PACKAGE="chtcollectd_v"$1".rpm"
    PACKAGE_CMD="rpm --force"
  else
    echo "Only supporting debian and redhat-based distributions currently" 2>&1 | tee -a /tmp/agent_install_log.txt
    abort_agent_install
  fi
  install_component "$CHTCOLLECT_PACKAGE" v$AGENT_VERSION $CHTCOLLECT_PACKAGE
  $PACKAGE_CMD -i $CHTCOLLECT_PACKAGE 2>&1 | tee -a /tmp/agent_install_log.txt
   
  COLLECTD_CONF_DIR="/etc/chtcollectd"
  echo "Collectd conf dir: "$COLLECTD_CONF_DIR 2>&1 | tee -a /tmp/agent_install_log.txt

  if command_exists update-rc.d ; then
    if ! [ -f "/etc/init.d/chtcollectd" ] ; then
      install_component "chtcollectd_init_deb" v$AGENT_VERSION /etc/init.d/chtcollectd
      chmod ugo+x /etc/init.d/chtcollectd
    fi
    update-rc.d chtcollectd defaults
  elif command_exists chkconfig ; then
    if ! [ -f "/etc/init.d/chtcollectd" ] ; then
      install_component "chtcollectd_init_rh" v$AGENT_VERSION /etc/init.d/chtcollectd
      chmod ugo+x /etc/init.d/chtcollectd
    fi
    chkconfig --add chtcollectd
    chkconfig chtcollectd on
  else
    echo "Missing update-rc.d or chkconfig"  2>&1 | tee -a /tmp/agent_install_log.txt
    abort_agent_install
  fi

  # allow write permissions for the csv files for the cht_agent user
  chgrp -R cht_agent /var/lib/chtcollectd/
  chmod -R g+ws /var/lib/chtcollectd/
  echo "** Finished collectd install." 2>&1 | tee -a /tmp/agent_install_log.txt
fi


echo "** Installing agent under /opt/cht_perfmon/ ..." 2>&1 | tee -a /tmp/agent_install_log.txt

if test $PERFMON_ENV != "development" ; then
  cd /opt/
  rm -rf cht_perfmon
  if command_exists dpkg ; then
    PACKAGE_NAME="deb"
    PACKAGE_CMD="dpkg"
  elif command_exists rpm ; then
    PACKAGE_NAME="rpm"
    PACKAGE_CMD="rpm"
  else
    echo "Only supporting debian and redhat-based distributions currently" 2>&1 | tee -a /tmp/agent_install_log.txt
    abort_agent_install
  fi
  AGENT_NAME=cloudhealth-agent_v$1.$PACKAGE_NAME

  # needs these files to be present under s3.amazonaws.com/remote-collector/agent/:
  # cht_perfmon_initd, reinstall_cht_perfmon.sh, update_cht_perfmon.sh and cht_refresh_collectd (+ the package rpm and deb files)
  mkdir /etc/cht_perfmon
  install_component "$AGENT_NAME" v$AGENT_VERSION $AGENT_NAME
  install_component "cht_perfmon_initd" v$AGENT_VERSION /etc/init.d/cht_perfmon
  install_component "reinstall_cht_perfmon.sh" v$AGENT_VERSION /etc/cht_perfmon/reinstall_cht_perfmon.sh
  install_component "update_cht_perfmon.sh" v$AGENT_VERSION /etc/cht_perfmon/update_cht_perfmon.sh
  install_component "update_chtcollectd_data.sh" v$AGENT_VERSION /etc/cht_perfmon/update_chtcollectd_data.sh
  install_component "cht_agent_sudoers" v$AGENT_VERSION /etc/sudoers.d/cht_agent
  install_component "cht_refresh_collectd" v$AGENT_VERSION /etc/cron.daily/cht_refresh_collectd

  chmod 0440 /etc/sudoers.d/cht_agent
  chmod ugo+x /etc/init.d/cht_perfmon
  chmod ugo+x /etc/cht_perfmon/reinstall_cht_perfmon.sh
  chmod ugo+x /etc/cht_perfmon/update_cht_perfmon.sh
  chmod ugo+x /etc/cht_perfmon/update_chtcollectd_data.sh
  chmod ugo+x /etc/cron.daily/cht_refresh_collectd

  $PACKAGE_CMD -i $AGENT_NAME 2>&1 | tee -a /tmp/agent_install_log.txt
else
  PACKAGE_NAME="sandbox"
fi

install_perfmon () {
  if test $PERFMON_ENV != "development" ; then
    echo "** Setting up cht_perfmon" 2>&1 | tee -a /tmp/agent_install_log.txt
    chown -R cht_agent:cht_agent /opt/cht_perfmon
    /opt/cht_perfmon/embedded/bin/cht_perfmon_installer.rb $KEY $COLLECTD_CONF_DIR $CLOUD $PACKAGE_NAME $PERFMON_ENV $AGENT_VERSION $PROXY_HOST $PROXY_PORT $PROXY_USER $PROXY_PASSWORD 2>&1 | tee -a /tmp/agent_install_log.txt
    if command_exists update-rc.d ; then
      update-rc.d cht_perfmon defaults
    elif command_exists chkconfig ; then
      chkconfig --add cht_perfmon
      chkconfig cht_perfmon on
    fi

    echo "** Restarting cht_perfmon" 2>&1 | tee -a /tmp/agent_install_log.txt
    sudo /etc/init.d/cht_perfmon restart 2>&1 | tee -a /tmp/agent_install_log.txt
  else
    /opt/cht_perfmon/embedded/bin/cht_perfmon_installer.rb $KEY $COLLECTD_CONF_DIR $CLOUD $PACKAGE_NAME $PERFMON_ENV $AGENT_VERSION $PROXY_HOST $PROXY_PORT $PROXY_USER $PROXY_PASSWORD 2>&1 | tee -a /tmp/agent_install_log.txt
  fi
}

verify_collectd () {
    rm -rf /var/lib/chtcollectd/rrd
    rm -rf /etc/chtcollectd/collection.conf

    user_defined_frequency=$(grep -A 1 "LoadPlugin cpu" /etc/chtcollectd/collectd.conf | grep Int | awk '{print $2}')

    /etc/init.d/chtcollectd restart 2>&1 | tee -a /tmp/agent_install_log.txt
    echo "** Verifying that cht_perfmon output directories are populated by collectd" 2>&1 | tee -a /tmp/agent_install_log.txt
    sleep 3; printf .; sleep 3; printf .; sleep 3; printf .; sleep 3; printf .
    counter=1

    if [ $user_defined_frequency -gt 60 ]; then
      echo "Skipping check, sampling frequency of X larger than 1minute."
    else
      while [ ! `find /var/lib/chtcollectd/ -maxdepth 2 -name "cpu-average"` ]; do
        sleep 3; printf .
        counter=$((counter+1));

        if [ $counter -gt $((user_defined_frequency)) ]; then
          echo "Could not verify sucessful installation, stopping collectd" 2>&1 | tee -a /tmp/agent_install_log.txt
          /etc/init.d/chtcollectd stop
          abort_agent_install
        fi;
      done
    fi;

    echo .

    chmod -R ugo+rw /var/lib/chtcollectd

    if test $SUDOER_MOD != "do-not-modify-sudoers"; then
      echo "** All is well, commenting out requiretty, !visiblepw in sudoers (if present) to finish" 2>&1 | tee -a /tmp/agent_install_log.txt
      sudo sed -i '/Defaults \+requiretty/ s/^/#/' /etc/sudoers
      sudo sed -i '/Defaults \+!visiblepw/ s/^/#/' /etc/sudoers
    else
      echo "** Skipping modification of sudoers" 2>&1 | tee -a /tmp/agent_install_log.txt
    fi

    echo "** Done. ..." 2>&1 | tee -a /tmp/agent_install_log.txt
}

install_perfmon

if test $SKIP_COLLECTD = false ; then
  echo "** Restarting collectd with cht_perfmon configs" 2>&1 | tee -a /tmp/agent_install_log.txt
  # updating collectd
  sleep 10
  if is_perfmon_running ; then
    verify_collectd
  else
    echo "Could not verify cht_perfmon was running, stopping collectd" 2>&1 | tee -a /tmp/agent_install_log.txt
    /etc/init.d/chtcollectd stop
    abort_agent_install
  fi
fi

remove_dup_processes

#remove the lock file if exist. This lock file was created during auto update installation
file="/tmp/agent_install.lock"

if [ -f $file ] ; then
    rm $file
fi

echo "** Finished CHT Performance Agent install." 2>&1 | tee -a /tmp/agent_install_log.txt
echo "** Done." 2>&1 | tee -a /tmp/agent_install_log.txt
exit 0
