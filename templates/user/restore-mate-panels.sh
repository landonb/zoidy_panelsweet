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
#   command cp -- \
#     ~/.kit/ansible/roles/zoidy_panelsweet/templates/user/restore-mate-panels.sh \
#     ~/.local/bin
#   systemctl --user restart restore-mate-panels.service
#   # If mate-panels does not restart, run this:
#   mate-panel --replace &

# ***

# The screensaver name, e.g.:
#   org.gnome.ScreenSaver
#   org.freedesktop.ScreenSaver
SCREENSAVER_ID="org.mate.ScreenSaver"
DCONF_DIR="/org/mate/panel/"
DCONF_DUMP_NAME="dconf--org-mate-panel.dump"
DCONF_DUMP_CANON="${HOME}/.local/share/zoidy_panelsweet/${DCONF_DUMP_NAME}"

# CPYST/2024-03-05: Compare dump to current `dconf` settings:
#   diff "${DCONF_DUMP_CANON}" <(dconf dump ${DCONF_DIR})

# ***

# Good practice: exit if unset variable used.
set -o nounset

# Lock file path
PID_FILE="/tmp/restore-mate-panels.sh.pid"
# Log file path
LOG_FILE="/tmp/restore-mate-panels.sh.log"
MAX_LOG_LNS=${MAX_LOG_LNS:-10000}
# Tmp dump path
DCONF_DUMP_AFTER="/tmp/restore-mate-panels.dump.after"

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

# ***

# Simple logging mechanism
log() {
  echo "$(date +%Y-%m-%d\ %X) -- ${USER} -- \"$@\"" >> "${LOG_FILE}"
}

# ***

# The meat of what this daemon does:
# - Restore the panel arrangement.
reload_mate_panel_dconf () {
  local force_reload="${1:-false}"

  local msg
  local icon="${ICON_UNCHANGED}"

  if msg="$(should_reload_mate_panel "${force_reload}")"; then
    force_reload=true
  fi

  if ! ${force_reload}; then
    if mate_panel_process_was_reborn "${force_reload}"; then
      force_reload=true
    fi
  fi

  dconf_load_previous_dump "${force_reload}"

  # ***

  if ${force_reload}; then
    icon="${ICON_REPLACED}"

    mate-panel --replace &
  else
    icon="${ICON_UNCHANGED}"
  fi

  # ***

  local dump_age
  if [ -s "${DCONF_DUMP_CANON}" ]; then
    dump_age="$(echo "$((($(date +%s) - $(date +%s -r "${DCONF_DUMP_CANON}")) / 60)) mins")"
  else
    dump_age="N/a"
  fi

  log "$(strip_and_normalize_whitespace "${msg}") [${dump_age} since dump]"

  notify_send "${msg}" "${icon}" "${dump_age}"

  # ***

  # Truncate the log file. Keep the last ${MAX_LOG_LNS} lines.
  if [ ${MAX_LOG_LNS} -ge 0 ] \
    && [ $(wc -l ${LOG_FILE} | cut -d" " -f1) -gt $((${MAX_LOG_LNS} * 2)) ] \
  ; then
    sed -i "${MAX_LOG_LNS},\$ d" "${LOG_FILE}"
  fi

  # ***

  if ! ${force_reload}; then
    prompt_reload_anyway
  fi
}

# ***

prompt_reload_anyway () {
  local question_txt="Reload mate-panel anyway?"

  zenity --question --text="${question_txt}" &
  local zenity_pid="$!"

  sleep ${RMP_ZENITY_TIMEOUT:-2.69} &
  local timeout_pid="$!"

  # ***

  while true; do
    if ! ps -p ${zenity_pid} > /dev/null; then
      kill -s 9 ${timeout_pid} > /dev/null 2>&1

      if wait ${zenity_pid}; then
        mate-panel --replace &
      fi

      break
    elif ! ps -p ${timeout_pid} > /dev/null; then
      kill -s 9 ${zenity_pid} > /dev/null 2>&1

      break
    else
      sleep ${RMP_WAIT_INTERVAL:-0.25}
    fi
  done
}

# ***

# SAVVY: Replace narrower spaces with single normal space,
#        and remove leading and trailing spaces.
strip_and_normalize_whitespace () {
  echo "$1" | sed 's/[  ]\+/ /g' | sed 's/^ \+//' | sed 's/ \+$//'
}

notify_send () {
  local msg="$1"
  local icon="${2:-emblem-important}"
  local dump_age="$3"

  local addendum=""
  if [ -n "${dump_age}" ]; then
    addendum="
             [${dump_age} since dump]"
  fi

  notify-send -i "${icon}" "\
 🟧🟨🟩🟦🟪🟫⬛🟫🟪🟦🟩🟨
 🟥   ${msg}  🟧
 ⬛🟫🟪🟦🟩🟨🟧🟥🟧🟨🟩🟦${addendum}"
}

# ***

should_reload_mate_panel () {
  local force_reload="$1"

  # SAVVY: Note the use of narrower spaces (` `, ` `) to make notify-send
  # box ornamentation align nicely.
  local msg

  if ! [ -s "${DCONF_DUMP_CANON}" ]; then
    force_reload=false

    msg="🌪️ dconf stash absent     "
  elif has_changed_mate_panel_dconf; then
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

# Get age of mate-panel.
# - If younger than when locked, assume panels got messed up and need a kick.
# - E.g.,
#   $ ps -o lstart -C mate-panel
#                    STARTED
#   Wed Mar 13 10:49:42 2024
mate_panel_process_was_reborn () {
  local force_reload="$1"

  local age_diff_s
  age_diff_s="$(print_mate_panel_process_age_since_dump_time)"

  if [ ${age_diff_s} -ge 0 ]; then
    force_reload=true
  fi

  ${force_reload}
}

print_mate_panel_process_age_since_dump_time () {
  local age_diff_s=0

  local msg=""
  local icon=""
  local addendum=""

  local output_lns
  output_lns=$(ps_query_mate_panel_start | wc -l)

  if [ ${output_lns} -ne 2 ]; then
    icon="appointment-angry"
    if [ ${output_lns} -lt 2 ]; then
      msg="❓❗ No \`mate-panel\`!?"
    else
      msg="❓❗ ≥2 \`mate-panel\`s!?"
    fi
  else
    local start_time
    start_time="$(date +%s -d "$(ps_query_mate_panel_start | tail +2)")"

    age_diff_s="$((${start_time} - $(date +%s -r "${DCONF_DUMP_CANON}")))"

    local age_diff_m=0
    age_diff_m="$((${age_diff_s} / 60))"

    if [ ${age_diff_s} -ge 0 ]; then
      # mate-panel newer than dump file, so mate-panel restarted after sleep/lock.
      icon="appointment-new"
      msg="❗ newer \`mate-panel\`! "
      addendum=" [mate-panel ${age_diff_m}m newer than dump]"
    else
      icon="face-tired"
      msg="✅  older \`mate-panel\`  "
      addendum=" [mate-panel $((${age_diff_m} * -1))m older than dump]"
    fi
  fi

  # AVOID: Strips everything after "❓❗":
  #   log "$(strip_and_normalize_whitespace ${msg})${addendum}"
  log "$(echo ${msg} | sed 's/^ \+//' | sed 's/ \+$//')${addendum}"

  if [ -n "${msg}" ]; then
    notify-send -i "${icon}" "\
 🦐💫🧟💦🍇💩💣💩🍇💦🧟💫
 💥   ${msg}  🦐
 💣💩🍇💦🧟💫🦐💥🦐💫🧟💦
${addendum}"
  fi

  echo "${age_diff_s}"
}

ps_query_mate_panel_start () {
  ps -o lstart -C mate-panel
}

# ***

dconf_load_previous_dump () {
  local force_reload="${1:-false}"

  if ! [ -s "${DCONF_DUMP_CANON}" ]; then
    local msg icon

    if [ -s "${DCONF_DUMP_AFTER}" ]; then
      msg="BWARE: dconf stash absent"
      icon="face-sick"
    else
      # No /tmp/restore-mate-panels.dump means user hasn't slept/locked
      # with daemon running, so not an error the stash absent.
      msg="HELLO: Inaugural restore-mate-panels runtime"
      icon="face-uncertain"
    fi

    log "${msg}"

    notify-send -i "${icon}" "${msg}" "$(basename -- "$0")"

    return 0
  fi 

  ${force_reload} || return 0

  cat "${DCONF_DUMP_CANON}" | dconf load ${DCONF_DIR}

  log "restored dconf ${DCONF_DIR} (${DCONF_DUMP_CANON})"
}

dump_mate_panel_dconf_canon () {
  dconf dump ${DCONF_DIR} \
    > "${DCONF_DUMP_CANON}"
}

dump_mate_panel_dconf_after () {
  dconf dump ${DCONF_DIR} \
    > "${DCONF_DUMP_AFTER}"
}

has_changed_mate_panel_dconf () {
  dump_mate_panel_dconf_after

  ! diff -q "${DCONF_DUMP_CANON}" "${DCONF_DUMP_AFTER}" > /dev/null
}

# ***

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
  local expr="$( \
    printf "%s %s" \
      "type=method_call,interface=${SCREENSAVER_ID}" \
      "type=signal,interface=${SCREENSAVER_ID}"
  )"

  log "➰ looping: dbus-monitor --address \"${DBUS_SESSION_BUS_ADDRESS}\" ${expr}"

  dbus-monitor --address "${DBUS_SESSION_BUS_ADDRESS}" ${expr} | \
    while read line; do
      if echo "${line}" | grep -q "interface=${SCREENSAVER_ID}; member=Lock$"; then
        log "session locked"
        # Note that "screensaver active" always follows.

        dump_mate_panel_dconf_canon

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
                dump_mate_panel_dconf_canon
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

