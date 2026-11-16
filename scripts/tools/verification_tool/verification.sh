#!/bin/bash
#
# Purpose: The purpose of this verification script is to attempt to verify the RL1 environment 
#          is installed and configured correctly. It checks permissions, file/directory ownership,
#          group permissions, package dependencies are met, key programs like satdump, meteordemod,
#          are linked and execute without error during a dry run.
#
# Author:  Richard Creasey (AI4Y)
#
# Created: July 15th, 2024

# Input parameters:
#
#   1. Input mode  [quick|full]
#
# Example:
#         ./verification.sh quick
#         ./verification.sh full

# input params
MODE=$1

echo ""
if [[ -z ${MODE} ]]; then
  echo "Argument required:  ./verification.sh quick    or    ./verification.sh full"
  echo "                        (~ 1 minute)                       (~ 5 minutes)"
  echo ""
  exit 1
else
  vMODE=$(echo ${MODE} | tr '[:lower:]' '[:upper:]')
  if [[ ${vMODE} != "QUICK" && ${vMODE} != "FULL" ]]; then
    echo "Argument required:  ./verification.sh quick    or    ./verification.sh full"
    echo "                        (~ 1 minute)                       (~ 5 minutes)"
    echo ""
    exit 1
  fi
fi

start=$(date +%s)

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

LANG=POSIX
VALIDATION_LOG=/var/log/raspberry-lrpt/verification.log
PERMISSIONS_LIST=/home/$USER/raspberry-lrpt/scripts/tools/verification_tool/config/permissions.list
PERMISSIONS_OTHER_LIST=/home/$USER/raspberry-lrpt/scripts/tools/verification_tool/config/permissions_other.list
PACKAGE_LIST=/home/$USER/raspberry-lrpt/scripts/tools/verification_tool/config/package.list
TEST_FILES=$HOME/raspberry-lrpt/scripts/tools/verification_tool/test_files
mkdir -p -m 755 ${TEST_FILES}/tmp
declare -A levels=([PASS]=1 [FAIL]=2 [INFO]=3)
log_level=${LOG_LEVEL}
FAILURES=0
PASSES=0
echo "" > $VALIDATION_LOG

TEST_LOG=/tmp/verficiation_test.log
PIP_LOG=/tmp/pip_installed.log
BIN_SCRIPT=/tmp/verficiation_test.sh
LDD=$(which ldd)

# loggit function
loggit() {
  local log_type=$1
  local log_message=$2

  echo "${log_type} : ${log_message}"

  # log output to a log file
  echo $(date '+%d-%m-%Y %H:%M') "${log_type} : ${log_message}" >> "$VALIDATION_LOG"

}


# The function will test and report
perms() {

  localuser=$USER

  ptype=$1
  #echo "ptype=${ptype}"
  if [[ "${ptype}" == "file" ]]; then
    ptype="regular file"
  elif [[ "${ptype}" == "symbolic" ]]; then 
    ptype="symbolic link"
  fi

  rperms=$2
  owner=$3
  #echo "owner=${owner}"
  if [[ "${owner}" == "\$USER" ]]; then
    #echo "Setting owner, current owner=${owner}, USER=${USER}, localuser=${localuser}"
    owner=$localuser
  #  echo "owner=${owner}"
  fi

  group=$4
  #echo "group=${group}"
  if [[ "${group}" == "\$USER" ]]; then
    group=$localuser
  #  echo "group=${group}"
  fi

  path=$5
  #echo "path=${path}"
  if [[ "${path}" == *"\$USER"* ]]; then
    path=$(echo ${path} | sed  -e "s/\$USER/${localuser}/g")
  #  echo "path=${path}"
  fi
  
  #echo "-----------------"
  #echo "ptype=${ptype}"
  #echo "rperms=${rperms}"
  #echo "owner=${owner}"
  #echo "group=${group}"
  #echo "path=${path}"
  #echo "-----------------"

  if [[ -e $path ]]; then
    status=$(stat -c "%F %a %U %G %n" ${path} | sed "s/^regular empty file/regular file/")
    amode=$(stat -c "%a" ${path})
    # a system whose umask is 002 (Raspberry Pi OS Trixie) adds group write: that is fine as long
    # as the group could already read it and nothing else differs
    gw_ok=0
    if (( (8#${rperms} & 8#040) )) && (( (8#${amode} | 8#020) == (8#${rperms} | 8#020) )); then gw_ok=1; fi
    if [[ "${status}" == "${ptype} ${rperms} ${owner} ${group} ${path}" ]] || \
       { [[ ${gw_ok} -eq 1 ]] && [[ "$(stat -c "%F %U %G %n" ${path} | sed "s/^regular empty file/regular file/")" == "${ptype} ${owner} ${group} ${path}" ]]; }; then
      loggit "PASS" "${status}"
      PASSES=$(expr ${PASSES} + 1)
    else
      loggit "FAIL" "****************************************************"
      loggit "FAIL" "CURRENT ${status}"
      loggit "FAIL" "DESIRED ${ptype} ${rperms} ${owner} ${group} ${path}"
      loggit "FAIL" "****************************************************"
      FAILURES=$(expr ${FAILURES} + 1)
    fi
  else
    loggit "FAIL" "$path does not exist"
    FAILURES=$(expr ${FAILURES} + 1)
  fi


}

# run as a normal user for any scripts within
if [ $EUID -eq 0 ]; then
  log "This script shouldn't be run as root." "ERROR"
  exit 1
fi

# There is a chance that this verification script is being executed after a fresh install of OS/RL1, so execute dryrun of satdump to precreate satdump configuration directories/files
CMD="/usr/bin/satdump live meteor_m2-x_lrpt . --source rtlsdr --samplerate 1.024e6 --frequency 137.1e6 --gain 49.6 --timeout 1"
echo ${CMD} > ${BIN_SCRIPT};chmod +x ${BIN_SCRIPT}
${BIN_SCRIPT} > ${TEST_LOG} 2>&1

loggit "INFO" ""
loggit "INFO" ""
loggit "INFO" ""
loggit "INFO" "************** Starting Validation **************"
loggit "INFO" ""
loggit "INFO" "*************************************************"
loggit "INFO" "*** Checking Ownership and Permissions ***"
loggit "INFO" "*************************************************"

while IFS= read -r line; do
  perms ${line}
done < ${PERMISSIONS_LIST}

while IFS= read -r line; do
  perms ${line}
done < ${PERMISSIONS_OTHER_LIST}

if grep -qE "^METEOR_DECODER=.?meteordemod" "$HOME/.raspberry-lrpt.conf" 2>/dev/null; then
  perms file 755 root root /usr/local/bin/meteordemod
  perms directory 755 \$USER \$USER /home/\$USER/.config/meteordemod
  perms file 644 \$USER \$USER /home/\$USER/.config/meteordemod/settings.ini
fi

# every script git marks executable must be executable here (a "git pull" keeps that bit)
not_x=0
while IFS= read -r f; do
  if [[ ! -x "$HOME/raspberry-lrpt/$f" ]]; then
    loggit "FAIL" "$HOME/raspberry-lrpt/$f is not executable (chmod +x it, or run ./install_and_upgrade.sh)"
    FAILURES=$(expr ${FAILURES} + 1); not_x=1
  fi
done < <(git -C "$HOME/raspberry-lrpt" ls-files -s 2>/dev/null | awk '$1 == "100755" {print $4}' | grep -v '^docs/')
if [[ ${not_x} -eq 0 ]]; then
  loggit "PASS" "All scripts in $HOME/raspberry-lrpt are executable"
  PASSES=$(expr ${PASSES} + 1)
fi

loggit "INFO" ""
loggit "INFO" "*************************************************"
loggit "INFO" "*** Checking required packages ***"
loggit "INFO" "*************************************************"

# installed means dpkg status "install ok installed"; "a|b" in the list means either package
pkg_installed() {
  local p
  for p in ${1//|/ }; do
    if [[ "$(dpkg-query -W -f='${db:Status-Status}' "$p" 2>/dev/null)" == "installed" ]]; then
      echo "$p $(dpkg-query -W -f='${Version}' "$p")"; return 0
    fi
  done
  return 1
}
while IFS= read -r line; do
  [[ -z "${line}" || "${line}" == \#* ]] && continue
  if found=$(pkg_installed "${line}"); then
    loggit "PASS" "${found}"
    PASSES=$(expr ${PASSES} + 1)
  else
    loggit "FAIL" "${line//|/ or } is not installed (run ./install_and_upgrade.sh)"
    FAILURES=$(expr ${FAILURES} + 1)
  fi
done < ${PACKAGE_LIST}

# the receiver's own drivers (receiver_type in settings.yml)
RECEIVER_SETTING=$(grep -E "^RECEIVER_TYPE=" "$HOME/.raspberry-lrpt.conf" 2>/dev/null | cut -d= -f2 | tr -d "'\"")
loggit "INFO" ""
loggit "INFO" "*** Checking drivers for the receiver: ${RECEIVER_SETTING:-unknown} ***"
receiver_packages=""
case "$RECEIVER_SETTING" in
  rtlsdr)
    receiver_packages="rtl-sdr librtlsdr0"
    perms file 644 root root /etc/modprobe.d/rtlsdr.conf
    if dpkg-query -W -f='${Version}' librtlsdr0 2>/dev/null | grep -q "rtlsdrblog"; then
      loggit "PASS" "librtlsdr0 is the RTL-SDR Blog driver ($(dpkg-query -W -f='${Version}' librtlsdr0))"; PASSES=$(expr ${PASSES} + 1)
    else
      loggit "FAIL" "librtlsdr0 is not the RTL-SDR Blog driver (run ./install_and_upgrade.sh)"; FAILURES=$(expr ${FAILURES} + 1)
    fi ;;
  airspy_mini|airspy_r2|airspy_hf_plus_discovery)
    [ "$RECEIVER_SETTING" == "airspy_hf_plus_discovery" ] && receiver_packages="airspyhf" || receiver_packages="airspy"
    perms file 644 root root /etc/modprobe.d/airspy-blacklist.conf
    perms file 644 root root /etc/udev/rules.d/52-airspy.rules ;;
  hackrf)
    receiver_packages="hackrf" ;;
  mirisdr)
    perms file 644 root root /etc/modprobe.d/blacklist-msi.conf
    perms file 644 root root /etc/udev/rules.d/66-mirisdr.rules ;;
  sdrplay)
    perms file 644 root root /etc/modprobe.d/blacklist-msi.conf
    perms file 644 root root /etc/udev/rules.d/66-sdrplay.rules
    perms file 755 root root /usr/local/bin/sdrplay_apiService
    if systemctl is-active --quiet sdrplay; then
      loggit "PASS" "sdrplay service is running"; PASSES=$(expr ${PASSES} + 1)
    else
      loggit "FAIL" "sdrplay service is not running (sudo systemctl status sdrplay)"; FAILURES=$(expr ${FAILURES} + 1)
    fi
    if ls /usr/lib/*/satdump/plugins/libsdrplay_sdr_support.so > /dev/null 2>&1; then
      loggit "PASS" "SatDump's SDRplay plugin is installed"; PASSES=$(expr ${PASSES} + 1)
    else
      loggit "FAIL" "SatDump's SDRplay plugin is missing (run ./install_and_upgrade.sh)"; FAILURES=$(expr ${FAILURES} + 1)
    fi ;;
esac
for line in $receiver_packages; do
  if found=$(pkg_installed "${line}"); then
    loggit "PASS" "${found}"
    PASSES=$(expr ${PASSES} + 1)
  else
    loggit "FAIL" "${line} is not installed (run ./install_and_upgrade.sh)"
    FAILURES=$(expr ${FAILURES} + 1)
  fi
done


loggit "INFO" ""
loggit "INFO" "*************************************************"
loggit "INFO" "*** Checking required PIP packages ***"
loggit "INFO" "*************************************************"

pip list > ${PIP_LOG}
for pip_package in envbash;
do 
  v_result=$(cat ${PIP_LOG} | grep ${pip_package});
  if [[ ${v_result} ]]; then
    loggit "PASS" "${v_result}"
    PASSES=$(expr ${PASSES} + 1)
  else
    loggit "FAIL" "Python package ${pip_package} is not installed"
    FAILURES=$(expr ${FAILURES} + 1)
  fi
done

loggit "INFO" ""
loggit "INFO" "*************************************************"
loggit "INFO" "*** Checking RL1 crontab jobs ***"
loggit "INFO" "*************************************************"

cronjob1="1 0 * * * ${HOME}/raspberry-lrpt/scripts/schedule.sh -t"
cronjob2="@reboot ${HOME}/raspberry-lrpt/scripts/schedule.sh"
cronjob3="@reboot ${HOME}/raspberry-lrpt/scripts/tools/scratch_perms.sh"
cron1=$(crontab -l | grep -v "^#" | grep -F "${cronjob1}" | wc -l)
cron2=$(crontab -l | grep -v "^#" | grep -F "${cronjob2}" | wc -l)
cron3=$(crontab -l | grep -v "^#" | grep -F "${cronjob3}" | wc -l)
crontotal=`expr ${cron1} + ${cron2} + ${cron3}`

if [[ ${crontotal} -eq 3 ]]; then
  loggit "PASS" "All RL1 enabled crontab jobs found"
else
  loggit "FAIL" "All RL1 enabled crontab jobs NOT found"
fi

loggit "INFO" ""
loggit "INFO" "*************************************************"
loggit "INFO" "*** Perform Dryrun Binary Tests ***"
loggit "INFO" "*************************************************"

###############################
# Dryrun Binary Test Commands #
###############################

NGINX="/usr/sbin/nginx"
WEB_PORT=$(grep -E "^WEBPANEL_PORT=" "$HOME/.raspberry-lrpt.conf" 2>/dev/null | cut -d= -f2 | tr -d "'\"")
if grep -qE "^ENABLE_TLS=true" "$HOME/.raspberry-lrpt.conf" 2>/dev/null; then WEB_URL="https://127.0.0.1"; else WEB_URL="http://127.0.0.1:${WEB_PORT:-80}"; fi
NGINX_CMD="code=\$(curl -sk -o /dev/null -w '%{http_code}' ${WEB_URL}/passes); echo \"web panel at ${WEB_URL}/passes answered HTTP \$code\"; [ \"\$code\" = 200 ]"

SATDUMP="/usr/bin/satdump"
SATDUMP_CMD="${SATDUMP} live meteor_m2-x_lrpt . --source rtlsdr --samplerate 1.024e6 --frequency 137.9e6 --fill_missing --gain 48 --timeout 1"

METEORDEMOD="/usr/local/bin/meteordemod"
METEORDEMOD_QCMD="${METEORDEMOD} -h"
METEORDEMOD_CMD="${METEORDEMOD} -m oqpsk -diff 1 -s 72000 -sat 'METEOR-M-2-3' -t '${TEST_FILES}/meteordemod-input.tle' -f jpg -i '${TEST_FILES}/meteordemod-input.cadu' -o '${TEST_FILES}/tmp'"



# MeteorDemod is only installed when it is the configured Meteor decoder
METEOR_DECODER_SETTING=$(grep -E "^METEOR_DECODER=" "$HOME/.raspberry-lrpt.conf" 2>/dev/null | cut -d= -f2 | tr -d "'\"")
BINS="${NGINX} ${SATDUMP}"
[ "${METEOR_DECODER_SETTING}" == "meteordemod" ] && BINS="${BINS} ${METEORDEMOD}"
for BIN in ${BINS} ;
do 
  BINNAME=$(echo ${BIN} | awk -F"/" '{print $NF}' | tr '[:lower:]' '[:upper:]')
  BINCMD="${BINNAME}_CMD"

  if [[ ! -x ${BIN} ]]; then
    loggit "FAIL" "${BIN} is not installed"
    FAILURES=$(expr ${FAILURES} + 1)
    continue
  fi
  v_lddresult=$(${LDD} ${BIN} | grep -i "not found" | wc -l)

  if [[ ${v_lddresult} -eq 0 ]]; then
    loggit "PASS" "${BIN} has all required libraries"
    PASSES=$(expr ${PASSES} + 1)

    # Perform Dry run execution since all libraries are dynamiclly linked
    #
    # Writing test command to a file to call for execution. SATDUMP and METEORDEMOD could be called 
    echo ${!BINCMD} > ${BIN_SCRIPT};chmod +x ${BIN_SCRIPT}
    if [[ ${BINNAME} == 'METEORDEMOD' && ${vMODE} == "FULL" ]]; then
      loggit "INFO" "*** FULL mode choosen *** - Please wait for meteordemod testing to complete... ~ 4 minutes"
      ${BIN_SCRIPT} >> ${TEST_LOG} 2>&1
      vResult=$?
      if (( ${vResult} )); then
        vError=$(cat ${TEST_LOG} | tail -1)
        loggit "FAIL" "${BIN} dry run failed: ${vError}"
        FAILURES=$(expr ${FAILURES} + 1)
      else
        loggit "PASS" "${BIN} dry run was successful"
        PASSES=$(expr ${PASSES} + 1)
      fi
    elif [[ ${BINNAME} != 'METEORDEMOD' ]]; then
      ${BIN_SCRIPT} >> ${TEST_LOG} 2>&1
      vResult=$?
      if (( ${vResult} )); then
        vError=$(cat ${TEST_LOG} | tail -1)
        loggit "FAIL" "${BIN} dry run failed: ${vError}"
        FAILURES=$(expr ${FAILURES} + 1)
      else
        loggit "PASS" "${BIN} dry run was successful"
        PASSES=$(expr ${PASSES} + 1)
      fi
    elif [[ ${BINNAME} == 'METEORDEMOD' ]]; then
      BINCMD="${BINNAME}_QCMD"
      echo ${!BINCMD} > ${BIN_SCRIPT};chmod +x ${BIN_SCRIPT}
      ${BIN_SCRIPT} >> ${TEST_LOG} 2>&1
      vResult=$?
      if (( ${vResult} )); then
        vError=$(cat ${TEST_LOG} | tail -1)
        loggit "FAIL" "${BIN} dry run failed: ${vError}"
        FAILURES=$(expr ${FAILURES} + 1)
      else
        loggit "PASS" "${BIN} dry run was successful"
        PASSES=$(expr ${PASSES} + 1)
      fi
    fi
  else
    loggit "FAIL" "${BIN} is missing ${v_lddresult} required librarie(s)"
    FAILURES=$(expr ${FAILURES} + 1)
    loggit "FAIL" "${BIN} skipping dry run execution due to missing librarie(s)"
    FAILURES=$(expr ${FAILURES} + 1)    
  fi

done

loggit "INFO" ""
loggit "INFO" "===================================================="
loggit "INFO" "Passing tests ${PASSES}    Failing tests ${FAILURES}"
loggit "INFO" "===================================================="
loggit "INFO" ""
loggit "INFO" "Log of results --> ${VALIDATION_LOG}"
loggit "INFO" ""
loggit "INFO" "************** Ending Validation ****************"

##################################################
# Clean up temporary files used during execution #
##################################################

if [[ -f  ${BIN_SCRIPT} ]]; then
  \rm -f ${BIN_SCRIPT} ${PIP_LOG} raw_*.png product.cbor dataset.json ${TEST_FILES}/tmp/*.bmp ${TEST_FILES}/tmp/*.dat 2>/dev/null
fi

secs_to_human "$(($(date +%s) - ${start}))"
