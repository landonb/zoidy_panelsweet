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
#   # If mate-panels does not restart, run this:
#   mate-panel --replace &

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
  echo "$(date +%Y-%m-%d\ %X) -- ${USER} -- \"$@\"" >> "${logfile}"
}

# The meat of what this daemon does:
# - Restore the panel arrangement.
reload_mate_panel_dconf () {
  cat "${DCONF_DUMP}" \
    | dconf load ${DCONF_DIR}

  log "restored dconf ${DCONF_DIR}"

  local msg

  if has_changed_mate_panel_dconf; then
    # MAYBE/2024-02-27: I've never seen this path followed.
    # - MAYBE: Sleep after detecting unlock, or run dbus-monitor
    #   without expression and look for a later event to hook.
    #   I.e., maybe mate-panel dconf is changed after the
    #   ActiveChanged event signals.
    msg="✗ replaced mate-panel"
  else
    msg=" ✓  dconf unchanged      "
  fi

  log "${msg}"

  notify-send -i "computer-fail" " 🟧🟨🟩🟦🟪🟫⬛🟫🟪🟦🟩🟨
 🟥   ${msg}  🟧
 ⬛🟫🟪🟦🟩🟨🟧🟥🟧🟨🟩🟦
"

  # This was originally in the `has_changed_mate_panel_dconf` branch
  # above, but after using for a few days, that branch never appears to
  # run. So trying dump_mate_panel_dconf as soon as session is locked,
  # rather than atop this function; and trying --replace always (here),
  # rather than in the `has_changed_mate_panel_dconf` if-branch.
  mate-panel --replace &

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

# Here's what you might see when locking, then unlocking the session.
# - It's similar to letting the computer idle and the screensaver activating,
#   in which case you'll see both ActiveChanged lines but not the Lock message.
#
# method call time=1709087779.758303 sender=:1.8518 -> destination=org.mate.ScreenSaver
#   serial=3 path=/org/mate/ScreenSaver; interface=org.mate.ScreenSaver; member=Lock
# signal time=1709087781.205881 sender=:1.36 -> destination=(null destination) serial=197
#   path=/org/mate/ScreenSaver; interface=org.mate.ScreenSaver; member=ActiveChanged
#    boolean true
# signal time=1709087785.998767 sender=:1.36 -> destination=(null destination) serial=198
#   path=/org/mate/ScreenSaver; interface=org.mate.ScreenSaver; member=ActiveChanged
#    boolean false

screen_locked=true
prev_line=""

# Usually `dbus-daemon` address can be guessed (`-s` returns 1st PID found)
# - Pipe to `xargs -0` to suppress message:
#   bash: warning: command substitution: ignored null byte in input
export $(grep -z DBUS_SESSION_BUS_ADDRESS /proc/$(pidof -s dbus-daemon)/environ | xargs -0)

# DBus watch expression
expr="type=method_call,interface=${SCREENSAVER_ID} type=signal,interface=${SCREENSAVER_ID}"

log "➰ looping: dbus-monitor --address \"${DBUS_SESSION_BUS_ADDRESS}\" ${expr}"

dbus-monitor --address "${DBUS_SESSION_BUS_ADDRESS}" ${expr} | \
  while read line; do
    if echo "${line}" | grep -q "; member=Lock$"; then
      log "session locked"

      screen_locked=true
      prev_line=""
    else
      if echo "${prev_line}" | grep -q "; member=ActiveChanged$"; then
        case "${line}" in
          *"boolean true"*)
            log "screensaver active"

            dump_mate_panel_dconf
            ;;
          *"boolean false"*)
            if ${screen_locked}; then
              log "session unlocked"

              reload_mate_panel_dconf

              screen_locked=false
            else
              log "screensaver latent"
            fi
            ;;
        esac
      fi
      prev_line="${line}"
    fi
  done

# Avoid leaving orphaned lock file when the loop ends (e.g. dbus dies)
cleanup

