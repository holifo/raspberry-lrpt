#!/bin/bash
#
# Purpose: The purpose of this uninstall script is to remove the RL1 environment
#          and key packages like satdump and predict. As well
#          as removal of RL1 crontab entries and Audio, Videos and Images in /srv
#
#          Software other programs may share is only removed if you say so: it asks about
#          the web server (nginx and PHP) and the RTL-SDR driver package (Enter keeps them).
#          A kept nginx gets its own site back if the install saved one
#          (default.before-raspberry-lrpt-<date>).
#
# Author:  Richard Creasey (AI4Y)
#
# Created: July 20th, 2024

start=$(date +%s)

UNINSTALL_LOG=/tmp/uninstall.log
PACKAGES="satdump predict"
OS=$(. /etc/os-release && echo "${DEBIAN_CODENAME:-$VERSION_CODENAME}")
case "${OS}" in
  trixie)   PHP=8.4 ;;
  bookworm) PHP=8.2 ;;
  *) echo "Aborting, unsupported Operating System ${OS}"; exit 1 ;;
esac
WEB_PACKAGES="nginx php${PHP}-intl php${PHP}-sqlite3 php${PHP}-mbstring php${PHP}-fpm"
WEB_SERVICES="phpsessionclean.service phpsessionclean.timer nginx.service"
PATHS="/srv/audio /srv/videos /srv/images $HOME/.config/composer $HOME/.config/gmic $HOME/.config/matplotlib $HOME/.config/satdump $HOME/raspberry-lrpt $HOME/.predict $HOME/.raspberry-lrpt.conf /usr/local/bin/rtl_* /var/log/raspberry-lrpt /etc/logrotate.d/raspberry-lrpt /etc/sudoers.d/020_www-data-atrm-nopasswd /etc/sudoers.d/030_www-data-switch /etc/sudoers.d/040_rl1-sdrplay-restart /var/www/wx-new /tmp/rtl-sdr /etc/modprobe.d/rtlsdr.conf /usr/share/satdump/resources/lut/cal/rl1_rain.png"
SITES=${NGINX_SITES:-/etc/nginx/sites-available}
ENABLED=${NGINX_ENABLED:-/etc/nginx/sites-enabled}

# asks on the terminal; Enter (or no terminal) keeps the software
ask_remove() {
  local a=""
  [ -r /dev/tty ] && read -r -p "$1 [y/N] " a < /dev/tty
  [[ "$a" =~ ^[Yy] ]]
}

echo "Raspberry-LRPT uninstall: the station's programs, folders, settings and cron jobs go."
echo "Two kinds of software may also be used by other programs on this Pi:"
echo ""
REMOVE_WEB=false
if ask_remove "Remove the web server too (nginx and PHP)? Other websites on this Pi would stop."; then
  REMOVE_WEB=true; PACKAGES="${PACKAGES} ${WEB_PACKAGES}"
fi
if dpkg -s rtl-sdr >/dev/null 2>&1 && ask_remove "Remove the RTL-SDR driver package (rtl-sdr)? Other SDR programs use it."; then
  PACKAGES="${PACKAGES} rtl-sdr"
fi
echo ""

secs_to_human() {
    if [[ -z ${1} || ${1} -lt 60 ]] ;then
        min=0 ; secs="${1}"
    else
        time_mins=$(echo "scale=2; ${1}/60" | bc)
        min=$(echo ${time_mins} | cut -d'.' -f1)
        secs="0.$(echo ${time_mins} | cut -d'.' -f2)"
        secs=$(echo ${secs}*60|bc|awk '{print int($1+0.5)}')
    fi
    echo "Time Elapsed : ${min} minutes and ${secs} seconds."
}

# loggit function
loggit() {
  local log_type=$1
  local log_message=$2

  echo "${log_type} : ${log_message}"

  # log output to a log file
  echo $(date '+%d-%m-%Y %H:%M') "${log_type} : ${log_message}" >> "$UNINSTALL_LOG"

}

# Check Package status
package_statuses() {

  loggit "INFO" ""
  loggit "INFO" "------------------------------"
  loggit "INFO" "Package statues"
  loggit "INFO" "------------------------------"
  for package in `echo ${PACKAGES}`;
  do
  
    PkgInstalled=$(sudo dpkg -s ${package} 2>/dev/null | grep -i "Status:" | wc -l)
  
    if [[ ${PkgInstalled} -eq 1 ]]; then
      loggit "INFO" "${package} is installed"
    else
      loggit "INFO" "${package} is NOT installed"
    fi
 
  done
}

remove_services() {

  loggit "INFO" ""
  loggit "INFO" "------------------------------"
  loggit "INFO" "Remove RL1 Services"
  loggit "INFO" "------------------------------"
  $REMOVE_WEB || { loggit "INFO" "Keeping nginx and PHP running"; return; }
  for svc in `echo ${WEB_SERVICES}`;
  do
   
    loggit "INFO" "Stopping and removing ${svc} service"
    sudo systemctl stop ${svc}
	  # Disable causes it to remain disabled even after the service is removed and reinstalled by Ansible 
	  # this is because disable removes /etc/systemd/system/multi-user.target.wants/nginx.service and is not added back when Ansible installs it. 
	  # If Ansible had issued an systemctl enable nsinx enable it would worked. 
	  # Commenting out the disable command because disabling the service is no impact since it will be removed when removing packages 
    # sudo systemctl disable ${svc}
     
  done

}

# Remove software packages
remove_packages() {

  loggit "INFO" ""
  loggit "INFO" "------------------------------"
  loggit "INFO" "Removing packages"
  loggit "INFO" "------------------------------"
  
  for pkg in `echo ${PACKAGES}`;
  do
  
    v_result=$(sudo apt -y remove --purge ${pkg} 2>&1>/dev/null )
  
    PkgInstalled=$(sudo dpkg -s ${pkg} 2>/dev/null | grep -i "Status:" | wc -l)
 
    if [[ ${PkgInstalled} -eq 1 ]]; then
      loggit "INFO" "${pkg} is installed"
    else
      loggit "INFO" "${pkg} is no longer installed"
    fi
  
  done
}

remove_paths() {

  loggit "INFO" ""
  loggit "INFO" "------------------------------"
  loggit "INFO" "Removing Files and Directories"
  loggit "INFO" "------------------------------"
  for path in `echo ${PATHS}`;
  do
  
    sudo rm -rf ${path}
  
    if ! (( $? )); then
      loggit "PASS" "${path} no longer exists"
    else
      loggit "FAIL" "${path} failed to remove"
    fi

  done  
}

# nginx kept: take the web panel's site out and give back the site the install saved, if any
web_site() {
  loggit "INFO" ""
  loggit "INFO" "------------------------------"
  loggit "INFO" "Web panel site in nginx"
  loggit "INFO" "------------------------------"
  for site in default default-tls; do
    f="${SITES}/${site}"
    if [ -f "$f" ] && grep -qE 'Raspberry-LRPT web panel|/var/www/wx-new' "$f"; then
      sudo rm -f "$f" "${ENABLED}/${site}"
      loggit "PASS" "web panel site ${site} removed"
    fi
    if ! $REMOVE_WEB; then
      saved=$(ls -1 "$f".before-raspberry-lrpt-* 2>/dev/null | sort | tail -1)
      if [ -n "$saved" ] && [ ! -e "$f" ]; then
        sudo mv "$saved" "$f" && sudo ln -sf "$f" "${ENABLED}/${site}" &&
          loggit "PASS" "your own site ${site} is back (from $(basename "$saved"))"
      fi
    fi
  done
  if ! $REMOVE_WEB && command -v nginx >/dev/null; then
    if sudo nginx -t >/dev/null 2>&1; then
      sudo systemctl reload nginx && loggit "PASS" "nginx reloaded"
    else
      loggit "FAIL" "nginx's configuration has an error now - check it with: sudo nginx -t"
    fi
  fi
}

# kill any RL1 AT processes as part of clean up, otherwise danglers 
# may have the RTL-SDR open and verification dryrun test will fail

ps aux | grep -E "receive_|satdump" | grep -v grep | awk -F" " '{print $2}' | xargs kill -9 2>/dev/null
package_statuses
remove_services
remove_packages
remove_paths
web_site

loggit "INFO" ""
loggit "INFO" "------------------------------"
loggit "INFO" "Removing RL1 CRON jobs"
loggit "INFO" "------------------------------"

# only the station's jobs (and the "#Ansible: <name>" line above each); other jobs stay
crontab -l 2>/dev/null | awk '
  /^#Ansible: / { held = $0; next }
  /raspberry-lrpt\/scripts\// { held = ""; next }
  { if (held != "") print held; held = ""; print }
  END { if (held != "") print held }' > $HOME/crontab.stripped
crontab < $HOME/crontab.stripped
CronQty=$(crontab -l 2>/dev/null | grep -c "raspberry-lrpt/scripts/")

if [[ ${CronQty} -eq 0 ]]; then
  loggit "PASS" "RL1 cronjobs no longer exist"
  \rm -rf $HOME/crontab.stripped
else
  loggit "FAIL" "RL1 cronjobs were NOT removed"
fi

# Let's make sure to clean up the library cache so any dangling items are cleared
sudo ldconfig

loggit "INFO" ""
loggit "INFO" "Log of results --> ${UNINSTALL_LOG}"
echo ""

secs_to_human "$(($(date +%s) - ${start}))"
