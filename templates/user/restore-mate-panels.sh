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

# CPYST/2024-03-05:
#   diff "${DCONF_DUMP}" <(dconf dump ${DCONF_DIR})

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
PID_FILE="/tmp/restore-mate-panels.sh.pid"
# Log file path
LOG_FILE="/tmp/restore-mate-panels.sh.log"
MAX_LOG_LNS=${MAX_LOG_LNS:-10000}
# Tmp dump path
DCONF_DUMP="/tmp/restore-mate-panels.dump"

# ***

# These notify-send icons were picked for the 'Mint-L' theme (LM 21.3).
# - You can change these to match icons you like for your preferred theme.
#   And you can use this copy-pasta to browse the icons for your theme.

__CPYST__="$(
cat <<'EOF'
  icon_theme="$( \
    gsettings get org.mate.interface icon-theme \
    | sed "s/^'//" | sed "s/'\$//"
  )"
  # Open gthumb, then look for *48/ directories.
  gthumb /usr/share/icons/${icon_theme}/ &
  # ALTLY: (BWARE: Don't run similar using gthumb):
  eog $(find /usr/share/icons/${icon_theme} -path *48/*.png)
EOF
)"

ICON_REPLACED="${ICON_REPLACED:-computer-fail}"

ICON_UNCHANGED="${ICON_UNCHANGED:-edit-clear-all}"

# ***

# Cleanup trap
cleanup() {
  # Remove the lock file
  command rm -f "${PID_FILE}"
  # Reset kernel signal catching
  trap - INT TERM EXIT
  # "Buy bye"
  log "daemon stopped"
  # Stop the daemon
  exit
}

# Simple logging mechanism
log() {
  echo "$(date +%Y-%m-%d\ %X) -- ${USER} -- \"$@\"" >> "${LOG_FILE}"
}

# The meat of what this daemon does:
# - Restore the panel arrangement.
reload_mate_panel_dconf () {
  local force_reload="${1:-false}"

  local msg
  local icon="${ICON_UNCHANGED}"

  if msg="$(should_reload_mate_panel "${force_reload}")"; then
    force_reload=true
  fi

  dconf_load_always

  if ${force_reload}; then
    icon="${ICON_REPLACED}"

    mate-panel --replace &
  else
    icon="${ICON_UNCHANGED}"
  fi

  log "${msg}"

  notify-send -i "${icon}" " 🟧🟨🟩🟦🟪🟫⬛🟫🟪🟦🟩🟨
 🟥   ${msg}  🟧
 ⬛🟫🟪🟦🟩🟨🟧🟥🟧🟨🟩🟦
"

  # Truncate the log file. Keep the last ${MAX_LOG_LNS} lines.
  if [ ${MAX_LOG_LNS} -ge 0 ]; then
    sed -i "${MAX_LOG_LNS},\$ d" "${LOG_FILE}"
  fi
}

# ***

should_reload_mate_panel () {
  local force_reload="$1"

  local msg

  if has_changed_mate_panel_dconf; then
    force_reload=true

    msg="✗ replaced mate-panel"
  elif ${force_reload}; then
    msg="✗ clobberd mate-panel"
  else
    msg=" ✓  dconf unchanged      "
  fi

  echo "${msg}"

  ${force_reload}
}

# ***

dconf_load_always () {
  cat "${DCONF_DUMP}" | dconf load ${DCONF_DIR}

  log "restored dconf ${DCONF_DIR} (always)"
}

dump_mate_panel_dconf () {
  suffix="${1:-}"

  dconf dump ${DCONF_DIR} \
    > "${DCONF_DUMP}${suffix}"
}

has_changed_mate_panel_dconf () {
  dump_mate_panel_dconf ".after"

  ! diff -q "${DCONF_DUMP}" "${DCONF_DUMP}.after" > /dev/null
}

main () {
  # Exit if lock file exists
  if [ -e "${PID_FILE}" ]; then
    log "$0 already running..."

    exit
  fi

  # Call cleanup() if e.g. killed
  trap cleanup INT TERM EXIT

  log "daemon started..."

  # Create lock file with own PID inside
  echo $$ > "${PID_FILE}"

  dump_mate_panel_dconf

  # Restore dconf on initial logon (or whenever this daemon is started)
  local force_reload=true
  reload_mate_panel_dconf "${force_reload}"

  # Here's what you might see when locking, then unlocking the session.
  # - It's similar to letting the computer idle and the screensaver activating,
  #   in which case you'll see both ActiveChanged lines but not the Lock message.
  #
  # method call time=1710185397.760220 sender=:1.8518 -> destination=org.mate.ScreenSaver
  #   serial=3 path=/org/mate/ScreenSaver; interface=org.mate.ScreenSaver; member=Lock
  # ...
  # signal time=1710185399.229279 sender=:1.36 -> destination=(null destination) serial=197
  #   path=/org/mate/ScreenSaver; interface=org.mate.ScreenSaver; member=ActiveChanged
  #    boolean true
  # signal time=1710185399.229530 sender=:1.15 -> destination=(null destination) serial=646
  #   path=/org/gnome/SessionManager/Presence; interface=org.gnome.SessionManager.Presence;
  #   member=StatusChanged
  #    uint32 3
  # # Locked
  # ...
  # # When Unlocked, or on Wake from screensaver
  # method call time=1710185406.138487 sender=:1.37 -> destination=org.freedesktop.DBus
  #   serial=105 path=/org/freedesktop/DBus; interface=org.freedesktop.DBus; member=AddMatch
  #    string "type='signal',interface='ca.desrt.dconf.Writer',path='/ca/desrt/dconf/Writer/user',
  #      arg0path='/org/mate/desktop/background/'"
  # ...
  # signal time=1710185410.112904 sender=:1.36 -> destination=(null destination) serial=198
  #   path=/org/mate/ScreenSaver; interface=org.mate.ScreenSaver; member=ActiveChanged
  #    boolean false

  local screen_locked=true
  local prev_line=""

  # Usually `dbus-daemon` address can be guessed (`-s` returns 1st PID found)
  # - Pipe to `xargs -0` to suppress message:
  #   bash: warning: command substitution: ignored null byte in input
  export $(grep -z DBUS_SESSION_BUS_ADDRESS /proc/$(pidof -s dbus-daemon)/environ | xargs -0)

  # DBus watch expression
  local expr="type=method_call,interface=${SCREENSAVER_ID} type=signal,interface=${SCREENSAVER_ID}"

  log "➰ looping: dbus-monitor --address \"${DBUS_SESSION_BUS_ADDRESS}\" ${expr}"

  dbus-monitor --address "${DBUS_SESSION_BUS_ADDRESS}" ${expr} | \
    while read line; do
      if echo "${line}" | grep -q "; member=Lock$"; then
        log "session locked"
        # Note that "screensaver active" always follows.

        dump_mate_panel_dconf

        screen_locked=true
        prev_line=""
      else
        if echo "${prev_line}" | grep -q "; member=ActiveChanged$"; then
          case "${line}" in
            *"boolean true"*)
              log "screensaver active"

              # Not sure it matters, but we dumped earlier, on "session locked".
              # - Just in case dconf changed since then, don't overwrite dump.
              if ! ${screen_locked}; then
                dump_mate_panel_dconf
              fi
              ;;
            *"boolean false"*)
              if ${screen_locked}; then
                log "session unlocked"

                screen_locked=false
              else
                log "screensaver latent"
              fi

              reload_mate_panel_dconf
              ;;
          esac
        fi
        prev_line="${line}"
      fi
    done

  # Avoid leaving orphaned lock file when the loop ends (e.g. dbus dies)
  cleanup
}

main

