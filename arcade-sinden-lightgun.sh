#!/bin/bash

# INSTALL:
# - copy arcade-sinden-lightgun.sh and arcade-sinden-lightgun.settings to /userdata/bin (create the directory if not present), and edit arcade-sinden-lightgun.settings for your needs
# - do a "chmod +x /userdata/bin/arcade-sinden-lightgun.sh"
# - add this lines in /usr/bin/virtual-sindenlightgun-add, just after the first line #!/bin/bash
#   if [ ! -f "/var/run/virtual-events.started" ]; then
#     exec 200>"/tmp/arcade-sinden-lightgun-init.lock"
#     if flock -n 200 && ( [ ! -f "/var/run/virtual-events.waiting" ] || ! grep -q "arcade-sinden-lightgun" "/var/run/virtual-events.waiting" ); then
#       echo "sindengun init - - /userdata/bin/arcade-sinden-lightgun.sh" >> /var/run/virtual-events.waiting
#     fi
#     exit 0
#   fi
# - add this line in /usr/bin/virtual-sindenlightgun-remap, just after the first line #!/bin/bash
#   /userdata/bin/arcade-sinden-lightgun.sh refresh && exit $?

WANTED_ORDER=("0xf39" "0xf38")

CMD_EVENTINFO="evtest --info"
CMD_EVENTINFO_STR_KB='Input device name: "Unknown SindenLightgun Keyboard"'
CMD_EVENTINFO_STR_MOUSE='Input device name: "Unknown SindenLightgun Mouse"'
ENV_FILE=/tmp/arcade-sinden-lightgun.env
MAX_WAIT=5

# ------------------------------------------------------

if [ -f arcade-sinden-lightgun.settings ]; then
    . arcade-sinden-lightgun.settings
else
    DIR=$(dirname $0)
    . $DIR/arcade-sinden-lightgun.settings
fi

GUNS_ORDERED=()
declare -A EVDEV_MOUSE
declare -A EVDEV_KB
declare -A EVDEV_ACM
declare -A EVDEV_HASH

device_add() {
    if [ "${EVDEV_KB[$1]}" ] || [ "${EVDEV_MOUSE[$1]}" ]; then
        echo "Adding lightgun $1 ..."
        if [ "${EVDEV_MOUSE[$1]}" ]; then
            echo "  adding mouse device /dev/input/${EVDEV_MOUSE[$1]} (and waiting for instance to start)..."
            udevadm trigger --action add "/dev/input/${EVDEV_MOUSE[$1]}"
            [ "${EVDEV_HASH[$1]}" ] && wait_for_file /var/run/sinden/p${EVDEV_HASH[$1]}/lockfile $MAX_WAIT && echo "    ... instance found" || echo "    ... instance NOT found, continuing with next guns"
        fi
        if [ "${EVDEV_KB[$1]}" ]; then
            echo "  adding keyboard device /dev/input/${EVDEV_KB[$1]} ..."
            udevadm trigger --action add "/dev/input/${EVDEV_KB[$1]}"
        fi
    else
        echo "Lightgun $1 not found"
    fi
}

device_remove() {
    if [ "${EVDEV_KB[$1]}" ] || [ "${EVDEV_MOUSE[$1]}" ]; then
        echo "Removing lightgun $1 ..."
        if [ "${EVDEV_MOUSE[$1]}" ]; then
            echo "  removing mouse device /dev/input/${EVDEV_MOUSE[$1]} ..."
            udevadm trigger --action remove "/dev/input/${EVDEV_MOUSE[$1]}"
        fi
        if [ "${EVDEV_KB[$1]}" ]; then
            echo "  removing keyboard device /dev/input/${EVDEV_KB[$1]} ..."
            udevadm trigger --action remove "/dev/input/${EVDEV_KB[$1]}"
        fi
    else
        echo "Lightgun $1 not found"
    fi
}

reset_env() {
    echo "Resetting environment (by killing running instances) ..."
    # kill any existing virtul-sindenlightgun
    ls /var/run/virtual-sindenlightgun-devices*.pid 2>/dev/null |
        while read VWMB
        do
            PID=$(cat "${VWMB}")
            echo "  killing virtual sindenlightgun (evsieve) with pid ${PID} ..."
            kill -15 "${PID}"
        done

    # remove exiting flags
    rm -rf /var/run/virtual-sindenlightgun-devices* || exit 1

    # kill the software
    N=$(pgrep -f LightgunMono | wc -l)
    echo "  killing $N running LightgunMono.exe instances ..."
    pgrep -f LightgunMono | xargs kill -15

    # kill lock files
    rm -f /var/run/sinden/*/lockfile

    for EL in "${GUNS_ORDERED[@]}"; do
        device_remove "$EL"
    done
    echo "Reset done."
}

is_in_array() {
    local value="$1"
    shift
    for elemento in "$@"; do
        [[ "$elemento" == "$value" ]] && return 0
    done
    return 1
}

wait_for_file() {
    SECONDS=0
    until [ -f "$1" ] || (( SECONDS >= $2 )); do sleep 0.1; done
    [ -f "$1" ] || return 1
    return 0
}

if [ ! "$1" ] && [ ! "$ACTION" ]; then
    echo "Syntax: $0 [rebuild|list|reorder|refresh|reverse|add|remove] [product_id]"
    echo "- rebuild: rebuild cached env file ${ENV_FILE}"
    echo "- list: list lightguns found"
    echo "- refresh: reset sinden lightgun environment (kill current processes) and re-add the guns in current order"
    echo "- reverse: reset sinden lightgun environment and re-add the guns in current reverse order"
    echo "- init: instance init, use only during boot process (in /boot/postshare.sh)"
    exit 1
fi

if [ "$1" == "rebuild" ]; then
    rm -f ${ENV_FILE}
fi

if [ -f ${ENV_FILE} ]; then
    . ${ENV_FILE}
else
    echo "Rebuiling env file ${ENV_FILE} ..."
    rm -f ${ENV_FILE}

    declare -A EVDEV_INFO
    GUNS_DETECTED=()
    for EVT in /dev/input/event*
    do
        EVTI=${EVT##*/}
        EVDEV_INFO[$EVTI]=$(${CMD_EVENTINFO} "${EVT}" 2>/dev/null | grep "Input device")
        if [[ "${EVDEV_INFO[$EVTI]}" =~ product[[:space:]](0x([a-z0-9]*))[[:space:]] ]]; then
            PRODUCTID="${BASH_REMATCH[1]}"
            if echo ${EVDEV_INFO[$EVTI]} | grep -qE "${CMD_EVENTINFO_STR_MOUSE}"
            then
                echo "Found Lightgun Mouse in ${EVTI}: ${PRODUCTID}"
                GUNS_DETECTED+=(${PRODUCTID})
                EVDEV_MOUSE["${PRODUCTID}"]=$EVTI
                ACMSEARCHDIR=/sys$(evsieve-helper parent-raw "${EVT}" input usb)
                ACM=$(find "${ACMSEARCHDIR}" -name "ttyACM*" | head -1)
                ACMDEV=/dev/$(basename "${ACM}")
                EVDEV_ACM["${PRODUCTID}"]=$ACMDEV
                PARENTHASH=$(evsieve-helper parent "${EVT}" input usb)
                EVDEV_HASH["${PRODUCTID}"]=$PARENTHASH
            fi
            if echo ${EVDEV_INFO[$EVTI]} | grep -qE "${CMD_EVENTINFO_STR_KB}"
            then
                echo "Found Lightgun Keyboard in ${EVTI}: ${PRODUCTID}"
                EVDEV_KB["${PRODUCTID}"]=$EVTI
            fi
        fi
    done

    GUNS_ORDERED=()
    for EL in "${WANTED_ORDER[@]}"; do
        if is_in_array "${EL}" "${GUNS_DETECTED[@]}"; then
            GUNS_ORDERED+=(${EL})
        else
            >&2 echo "ERRORE: Gun in WANTED_ORDER not found: ${EL}"
        fi
    done
    for EL in "${GUNS_DETECTED[@]}"; do
        if ! is_in_array "${EL}" "${WANTED_ORDER[@]}"; then
            GUNS_ORDERED+=(${EL})
            echo "Found a gun not in WANTED_ORDER, appending it to the list: ${EL}"
        fi
    done

    for EL in "${GUNS_ORDERED[@]}"; do
        echo "GUNS_ORDERED+=('${EL}')" >> ${ENV_FILE}
    done
    for KEY in "${!EVDEV_MOUSE[@]}"; do
        echo "EVDEV_MOUSE['${KEY}']='${EVDEV_MOUSE[${KEY}]}'" >> ${ENV_FILE}
    done
    for KEY in "${!EVDEV_KB[@]}"; do
        echo "EVDEV_KB['${KEY}']='${EVDEV_KB[${KEY}]}'" >> ${ENV_FILE}
    done
    for KEY in "${!EVDEV_ACM[@]}"; do
        echo "EVDEV_ACM['${KEY}']='${EVDEV_ACM[${KEY}]}'" >> ${ENV_FILE}
    done
    for KEY in "${!EVDEV_HASH[@]}"; do
        echo "EVDEV_HASH['${KEY}']='${EVDEV_HASH[${KEY}]}'" >> ${ENV_FILE}
    done

    echo "Rebuild done."
fi

if [ "$1" == "list" ]; then
    echo "Lightguns found (in requested order):"
    for EL in "${GUNS_ORDERED[@]}"; do
        echo "  $EL (Mouse: ${EVDEV_MOUSE[$EL]}, Keyboard: ${EVDEV_KB[$EL]}, ACM: ${EVDEV_ACM[$EL]}, HASH: ${EVDEV_HASH[$EL]})"
    done
    echo "Looking for running instances:"
    for EL in /var/run/sinden/*/*.config; do echo "${EL}: "; grep SerialPortWrite "$EL"; RUNNINGI="1"; done
    if [ ! "$RUNNINGI" ]; then echo "No running instances found."; fi
fi

if [ "$1" == "init" ] || [ "$ACTION" == "init" ]; then
    [ -f /tmp/arcade-sinden-lightgun.initialized ] && exit 0
    touch /tmp/arcade-sinden-lightgun.initialized
    echo "Init start ..."
    for EL in "${GUNS_ORDERED[@]}"; do
        echo "  adding gun $EL / mouse event: ${EVDEV_MOUSE[$EL]} (and waiting for instance to start)..."
        ACTION="add" DEVNAME="/dev/input/${EVDEV_MOUSE[$EL]}" DEVPATH="-" /usr/bin/virtual-sindenlightgun-add
        [ "${EVDEV_HASH[$EL]}" ] && wait_for_file /var/run/sinden/p${EVDEV_HASH[$EL]}/lockfile $MAX_WAIT && echo "    ... instance found" || echo "    ... instance NOT found, continuing with next guns"
    done
    echo "Init done."
fi

if [ "$1" == "refresh" ]; then
    reset_env
    for EL in "${GUNS_ORDERED[@]}"; do
        device_add "$EL"
    done
    echo "Refresh done."
fi

if [ "$1" == "reverse" ]; then
    reset_env
    for ((i=${#GUNS_ORDERED[@]}-1; i>=0; i--)); do
        device_add "${GUNS_ORDERED[$i]}"
    done
    echo "Reverse refresh done."
fi
