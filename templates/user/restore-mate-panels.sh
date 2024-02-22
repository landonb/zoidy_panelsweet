#!/bin/sh

# REFER/2024-02-16: As inspired by (and mostly copied from):
# https://unix.stackexchange.com/questions/28181/how-to-run-a-script-on-screen-lock-unlock/368632#368632
# - REFER: If you have multiple DBus lines, see:
#   - *Discover a DBUS Session Deterministically*
#     https://gist.github.com/naftulikay/f4c229b3c71fff9ac2102a0e03bd756f

# CXREF:
#   ~/.kit/ansible/roles/zoidy_panelsweet/tasks/panels-awesome.yml
#   ~/.kit/ansible/roles/zoidy_panelsweet/templates/user/restore-mate-panels.service

# CPYST/2024-02-21: After editing this file, either run the Ansible task:
#   ANSIBLE_DEBUG=0 ansible-playbook /path/to/site.yml -l $(hostname) --tags zoidy_panelsweet
# Or update ~/.local/bin and restart the service:
#   /bin/cp ~/.kit/ansible/roles/zoidy_panelsweet/templates/user/restore-mate-panels.sh ~/.local/bin
#   systemctl --user restart restore-mate-panels.service

# ***

# The screensaver name, e.g.:
#   org.gnome.ScreenSaver
#   org.freedesktop.ScreenSaver
SCREENSAVER_ID="org.mate.ScreenSaver"
DCONF_DIR="/org/mate/panel/"
DCONF_DUMP="${HOME}/.local/share/zoidy_panelsweet/dconf--org-mate-panel.dump"

# ***

# Good practice: exit if unset variable used.
set -o nounset

# Lock file path
pidfile=/tmp/restore-mate-panels.sh.pid
# Log file path
logfile=/tmp/restore-mate-panels.sh.log
log_lns=10000
# Tmp dump path
dumpfile=/tmp/restore-mate-panels.dump

# Cleanup trap
cleanup() {
  # Remove the lock file
  rm -f ${pidfile}
  # Reset kernel signal catching
  trap - INT TERM EXIT
  # "Buy bye"
  log "daemon stopped"
  # Stop the daemon
  exit
}

# Simple logging mechanism
log() {
  echo "$(date +%Y-%m-%d\ %X) -- ${USER} -- \"$@\"" >> ${logfile}
}

# The meat of what this daemon does:
# - Restore the panel arrangement.
reload_mate_panel_dconf () {
  dump_mate_panel_dconf

  cat "${DCONF_DUMP}" \
    | dconf load ${DCONF_DIR}

  log "restored dconf ${DCONF_DIR}"

  if has_changed_mate_panel_dconf; then
    mate-panel --replace &

    log "✗ replaced mate-panel"
  else
    log "✓ dconf unchanged"
  fi

  # Truncate the log file. Keep the last ${log_lns} lines.
  if [ ${log_lns} -ge 0 ]; then
    sed -i "${log_lns},\$ d" "${logfile}"
  fi
}

dump_mate_panel_dconf () {
  suffix="${1:-}"

  dconf dump ${DCONF_DIR} \
    > "${dumpfile}${suffix}"
}

has_changed_mate_panel_dconf () {
  dump_mate_panel_dconf ".after"

  ! diff -q "${dumpfile}" "${dumpfile}.after" > /dev/null
}

# Exit if lock file exists
if [ -e "${pidfile}" ]; then
  log "$0 already running..."

  exit
fi

# Call cleanup() if e.g. killed
trap cleanup INT TERM EXIT

log "daemon started..."

# Create lock file with own PID inside
echo $$ > ${pidfile}

# Restore dconf on initial logon (or whenever this daemon is started)
reload_mate_panel_dconf

# Usually `dbus-daemon` address can be guessed (`-s` returns 1st PID found)
# - Pipe to `xargs -0` to suppress message:
#   bash: warning: command substitution: ignored null byte in input
export $(grep -z DBUS_SESSION_BUS_ADDRESS /proc/$(pidof -s dbus-daemon)/environ | xargs -0)

# DBus watch expression
expr="type=signal,interface=${SCREENSAVER_ID}"

prev_line=""

dbus-monitor --address "${DBUS_SESSION_BUS_ADDRESS}" "${expr}" | \
  while read line; do
    if echo "${prev_line}" | grep -q "; member=ActiveChanged$"; then
      case "${line}" in
        *"boolean true"*)
          log "session locked"
          ;;
        *"boolean false"*)
          log "session unlocked"

          reload_mate_panel_dconf
          ;;
      esac
    fi
    prev_line="${line}"
  done

# Avoid leaving orphaned lock file when the loop ends (e.g. dbus dies)
cleanup

