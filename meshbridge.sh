#!/bin/bash
#set -x

################################################################################
#                  S C R I P T    S P E C I F I C A T I O N
################################################################################
#
# 20140327     Jason W. Plummer     Original: Let's build an AP mesh, shall we?
# 20140331     Jason W. Plummer     Formatted to the current format.  Added
#                                   sleep commands to all ifconfig and iw
#                                   commands.  Added fix to map wlan devices
#                                   to phy devices.  Added echo feedback for
#                                   network operations.  Added debug option to
#                                   config file.  Added support for hostapd
#                                   configuration and launch.
# 20140401     Jason W. Plummer     Added support for detecting mesh point
#                                   interface mode for a given radio device
#                                   in the make_mesh subroutine.  Added support
#                                   to create if necessary the dnsmasq config
#                                   file and start dnsmasq services.  Started
#                                   adding support for busybox command version.
# 20140403    Jason W. Plummer      Completed busybox command support for
#                                   proper operation on OpenWRT.  Added
#                                   more consistent standard out reporting of
#                                   operations.

################################################################################
# DESCRIPTION
################################################################################
#

# Name: meshbridge.sh

# This script does the following:
#
# 1. Sets the config directory to base directory of the config file
# 2. Parses the config file to set key/value variable pairs
# 3. Finds all ethernet bridges, removes their elements, then removes the 
#    bridge instance
# 4. Finds and takes offline all ethernet adapters
# 5. Finds and removes all ethernet routes
# 6. Makes a mesh according to the parameters in the config file, if defined
# 7. Makes an ethernet bridge according to the parameters in the config file,
#    if defined
# 8. Sets up the hostapd service according to the parameters in the config
#    file, if defined
# 9. Sets up the dnsmasq service according to the parameters in the config
#    file, if defined
#
# NOTE: In the case of hostapd and dnsmasq, there is some intelligence
#       built into the script to determine whether or not these services
#       should run as discrete IP specific services bound to a particular
#       network interface, or if they should be added to a bridge.
#
# NOTE: The script assumes that if a single argument is provided, that argument
#       is the path to a config file.  If no argument is given, the config
#       file is assumed to be located at /etc/meshbridge/meshbridge.conf
#

# Usage: ./meshbridge.sh <config file>

################################################################################
# CONSTANTS
################################################################################
#

PATH=/bin:/usr/bin:/usr/local/bin:/sbin:/usr/sbin:/usr/local/sbin
TERM=vt100
export PATH TERM

SUCCESS=0
ERROR=1

################################################################################
# VARIABLES
################################################################################
#

exit_code=${SUCCESS}
err_msg=""

return_code=${SUCCESS}

# Find our ps command
is_busybox=`ps --version 2>&1 | egrep -ic "busybox"`

if [ ${is_busybox} -gt 0 ]; then
    my_ps="ps"
else
    my_ps="ps -eaf"
fi

################################################################################
# SUBROUTINES
################################################################################
#
# kill_hostapd - a subroutine to terminate any running hostapd services
#
kill_hostapd() {
    return_code=${SUCCESS}

    if [ ${return_code} -eq ${SUCCESS} ]; then
        hostapd_check=`${my_ps} | egrep "hostapd" | egrep -v grep | wc -l`

        if [ ${hostapd_check} -gt 0 ]; then
            printf "%-73s" "Stopping service hostapd ... "

            # Try the nice way
            if [ -x /etc/init.d/hostapd ]; then
                /etc/init.d/hostapd stop > /dev/null 2>&1
                sleep 1
            fi

            hostapd_check=`${my_ps} | egrep "hostapd" | egrep -v grep | wc -l`

            # Try the less nice way
            if [ ${hostapd_check} -gt 0 ]; then

                case ${is_busybox} in

                    0)
                        hostapd_pids=`${my_ps} | egrep "hostapd" | egrep -v grep | awk '{print $2}'`
                    ;;

                    *)
                        hostapd_pids=`${my_ps} | egrep "hostapd" | egrep -v grep | awk '{print $1}'`
                    ;;

                esac

                for hostapd_pid in ${hostapd_pids} ; do
                    kill -9 ${hostapd_pid} > /dev/null 2>&1
                    sleep 1
                done

            fi

            hostapd_check=`${my_ps} | egrep "hostapd" | egrep -v grep | wc -l`

            if [ ${hostapd_check} -eq 0 ]; then
                echo "SUCCESS"
            else
                echo "FAILED"
                err_msg="Failed to terminate the hostapd service for mesh initialization"
                return_code=${ERROR}
            fi

        fi

    fi

    return ${return_code}
}

#
#-------------------------------------------------------------------------------
#
# kill_dnsmasq - a subroutine to terminate any running dnsmasq services
#
kill_dnsmasq() {
    return_code=${SUCCESS}

    if [ ${return_code} -eq ${SUCCESS} ]; then
        dnsmasq_check=`${my_ps} | egrep "dnsmasq" | egrep -v grep | wc -l`

        if [ ${dnsmasq_check} -gt 0 ]; then
            printf "%-73s" "Stopping service dnsmasq ... "

            # Try the nice way
            if [ -x /etc/init.d/dnsmasq ]; then
                /etc/init.d/dnsmasq stop > /dev/null 2>&1
                sleep 1
            fi

            dnsmasq_check=`${my_ps} | egrep "dnsmasq" | egrep -v grep | wc -l`

            # Try the less nice way
            if [ ${dnsmasq_check} -gt 0 ]; then

                case ${is_busybox} in

                    0)
                        dnsmasq_pids=`${my_ps} | egrep "dnsmasq" | egrep -v grep | awk '{print $2}'`
                    ;;

                    *)
                        dnsmasq_pids=`${my_ps} | egrep "dnsmasq" | egrep -v grep | awk '{print $1}'`
                    ;;

                esac

                for dnsmasq_pid in ${dnsmasq_pids} ; do
                    kill -9 ${dnsmasq_pid} > /dev/null 2>&1
                    sleep 1
                done

            fi

            dnsmasq_check=`${my_ps} | egrep "dnsmasq" | egrep -v grep | wc -l`

            if [ ${dnsmasq_check} -eq 0 ]; then
                printf "%s\n" "SUCCESS"
            else
                echo "FAILED"
                err_msg="Failed to terminate the dnsmasq service for mesh initialization"
                return_code=${ERROR}
            fi

        fi

    fi

    return ${return_code}
}
#
#-------------------------------------------------------------------------------
#
# flush_meshes - a subroutine to figure out what meshes we have and get rid of
#                them
#
flush_meshes() {
    return_code=${SUCCESS}

    if [ ${return_code} -eq ${SUCCESS} ]; then
        echo -ne "Looking for wireless meshes: "
        my_meshes=`ifconfig | egrep -i "^[a-z]" | awk '{print $1}' | egrep -i "^mesh[0-9].*$"`

        if [ "${my_meshes}" = "" ]; then
            echo "NONE"
        else
            echo ${my_meshes}
        fi

        for my_mesh in ${my_meshes} ; do
            iw dev ${my_mesh} del

            if [ ${?} -ne ${SUCCESS} ]; then
                echo "    WARNING:  Could not disable mesh ${my_mesh}"
                let return_code=${return_code}+1
            else
                echo "    Successfully removed mesh interface ${my_mesh}"
            fi

        done

    fi

    return ${return_code}
}

#
#-------------------------------------------------------------------------------
#
# check_ipaddr - a subroutine to make sure an IP address is properly formatted
#
check_ipaddr() {
    return_code=${SUCCESS}
    this_ip="${1}"

    if [ "${this_ip}" != "" ]; then
        printf "%-73s" "    Verifying IP address validity ... "
        err_msg="Invalid IP address"
        return_code=${ERROR}

        let octet_counter=1
        let octet_error=0

        for octet in `echo "${this_ip}" | awk -F'.' '{print $1 " " $2 " " $3 " " $4}'` ; do

            if [ ${octet_counter} -eq 1 -o ${octet_counter} -eq 4 ]; then

                if [ ${octet} -lt 1 -o ${octet} -gt 254 ]; then
                    let octet_error=${octet_error}+1
                fi

            else

                if [ ${octet} -lt 0 -o ${octet} -gt 254 ]; then
                    let octet_error=${octet_error}+1
                fi

            fi

            let octet_counter=${octet_counter}+1
        done

        if [ ${octet_error} -eq 0 ]; then
            echo "SUCCESS"
            return_code=${SUCCESS}
        else
            echo "FAILED"
        fi

    else
        err_msg="No IP address specified"
    fi

    return ${return_code}
}

#
#-------------------------------------------------------------------------------
#
# flush_bridges - a subroutine to figure out what bridges we have and get rid of
#                 them
#
flush_bridges() {
    return_code=${SUCCESS}

    # Find any existing ethernet bridges
    if [ ${return_code} -eq ${SUCCESS} ]; then
        echo -ne "Looking for ethernet bridges: "

        # Find all bridges
        my_bridges=`brctl show | egrep -iv "^bridge name" | egrep -n "^.*$" | egrep "^[0-9]*:[a-z]" | awk '{print $1}'`

        if [ "${my_bridges}" = "" ]; then
            echo "NONE"
        else
            echo ${my_bridges} | sed -e 's/[0-9]*://g'
        fi

        # Disable all bridges
        for my_bridge in ${my_bridges} ; do
            ifconfig `echo "${my_bridge}" | awk -F':' '{print $NF}'` down
            let start_line=`echo "${my_bridge}" | awk -F':' '{print $1}'`
            let end_line=`echo "${my_bridges}" | egrep -A1 "^${my_bridge}$" | tail -1 | awk -F':' '{print $1}'`

            # Make sure we aren't at the end of the list
            if [ ${end_line} -gt ${start_line} ]; then
                let end_line=${end_line}-1
            fi

            let grep_count=${end_line}-${start_line}

            # Get all members of bridge ${my_bridge}
            my_bridge=`echo "${my_bridge}" | awk -F':' '{print $NF}'`
            my_brnics=`brctl show | egrep -iv "^bridge name" | egrep -A${grep_count} "${my_bridge}" | awk '{print $NF}' | egrep -v "yes|no"`

            for my_brnic in ${my_brnics} ; do
                printf "%-73s" "    Removing ethernet device ${my_brnic} from bridge ${my_bridge} ... "
                brctl delif ${my_bridge} ${my_brnic}

                if [ ${?} -eq 0 ]; then
                    echo "SUCCESS"
                else
                    echo "FAILED"
                    echo "        Could not remove ethernet adapter ${my_brnic} from ethernet bridge ${my_bridge}"
                    let return_code=${return_code}+1
                fi

                sleep 2
            done

            if [ ${return_code} -eq ${SUCCESS} ]; then
                printf "%-73s" "    Removing ethernet bridge ${my_bridge} ... "
                brctl delbr ${my_bridge}

                if [ ${?} -eq 0 ]; then
                    echo "SUCCESS"
                else
                    echo "FAILED"
                    echo "        Could not remove ethernet bridge ${my_bridge}"
                    let return_code=${return_code}+1
                fi

                sleep 2
            fi

        done

        if [ ${return_code} -ne ${SUCCESS} ]; then
            err_msg="Errors were encountered while disabling existing ethernet bridges"
        fi

    fi

    return ${return_code}
}

#
#-------------------------------------------------------------------------------
#
# flush_nics - a subroutine to figure out what ethernet interfaces we have and 
#              disable them
#
flush_nics() {
    return_code=${SUCCESS}

    # Find and bring down all ethernet adapters
    if [ ${return_code} -eq ${SUCCESS} ]; then
        echo -ne "Looking for ethernet adapters: "

        # Find all NICS
        my_nics=`ifconfig | egrep "^[a-z]" | awk '{print $1}'`

        if [ "${my_nics}" = "" ]; then
            echo "NONE"
        else
            echo ${my_nics}
        fi
        
        for my_nic in ${my_nics} ; do
            printf "%-73s" "    Taking ethernet adapter ${my_nic} offline ... "
            ifconfig ${my_nic} down

            if [ ${?} -eq 0 ]; then
                echo "SUCCESS"
            else
                echo "FAILED"
                echo "        Failed to take ethernet adapter ${my_nic} offline" 
                let return_code=${return_code}+1
            fi

            sleep 2
        done

        if [ ${return_code} -ne ${SUCCESS} ]; then
            err_msg="Errors were encountered while disabling existing ethernet interfaces"
        fi

    fi

    return ${return_code}
}

#
#-------------------------------------------------------------------------------
#
# flush_routes - a subroutine to figure out what ethernet routes we have and 
#                get rid of them
#
flush_routes() {
    return_code=${SUCCESS}

    # Find and remove all ethernet route rules
    if [ ${return_code} -eq ${SUCCESS} ]; then
        echo -ne "Looking for route rules: "
        # Disable all routes
        my_routes=`route -n | egrep "^[0-9]" | awk '{print $1 ":" $3 ":" $NF}'`

        if [ "${my_routes}" != "" ]; then
            route_count=`echo "${my_routes}" | wc -l`
            echo "Found ${route_count}"
        else
            echo "NONE"
        fi

        let route_counter=1
        
        for my_route in ${my_routes} ; do
            target_ip=`echo "${my_route}" | awk -F':' '{print $1}'`
            target_netmask=`echo "${my_route}" | awk -F':' '{print $2}'`
            target_device=`echo "${my_route}" | awk -F':' '{print $NF}'`
            printf "%-73s" "    Deleting route rule ${route_counter} for ethernet adapter ${target_device} ... "
            route del -net ${target_ip} netmask ${target_netmask} dev ${target_device}

            if [ ${?} -eq 0 ]; then
                echo "SUCCESS"
            else
                echo "FAILED"
                let return_code=${return_code}+1
            fi

            let route_counter=${route_counter}+1
            sleep 2
        done

        if [ ${return_code} -ne ${SUCCESS} ]; then
            err_msg="Errors were encountered while disabling existing ethernet interfaces"
        fi

    fi

    return ${return_code}
}

#
#-------------------------------------------------------------------------------
#
# get_config - a subroutine to figure out what config options we need based on
#              what we've been asked to do
#
get_config() {
    return_code=${SUCCESS}

    # Parse config file and set variables defined in it
    if [ ${return_code} -eq ${SUCCESS} ]; then

        # The config file is a SAMBA/RSYNC style syntax with a bracketed header separating
        # key value pairs
        if [ -e "${conf_file}" ]; then
            sections=`egrep "^\[" "${conf_file}" | sed -e 's/\[//g' -e 's/\]//g'`

            for section in ${sections} ; do
                let start_line=`egrep -n "^\[${section}\]" "${conf_file}" | awk -F':' '{print $1}'`
                let end_line=`egrep -n "^\[" "${conf_file}" | egrep -A1 "\[${section}\]" | tail -1 | awk -F':' '{print $1}'`
                let grep_count=${end_line}-${start_line}

                for key_val_pair in `egrep -A${grep_count} "^\[${section}\]" "${conf_file}" | egrep -v "^\[|^$|^#" | sed -e 's/\ /:zzqc:/g'` ; do
                    key_val_pair=`echo "${key_val_pair}" | sed -e 's/:zzqc:/\ /g'`
                    eval "${key_val_pair}"
                    let return_code=${return_code}+${?}
                done

            done

            if [ ${return_code} -ne ${SUCCESS} ]; then
                err_msg="Errors were encountered loading config file \"${conf_file}\""
            fi

        else
            err_msg="Could not locate config file \"${conf_file}\""
            return_code=${ERROR}
        fi

    fi

    if [ "${debug}" = "yes" ]; then
        set -x
    fi

    return ${return_code}
}

#
#-------------------------------------------------------------------------------
#
# check_ethdevice - a subroutine to confirm that a given wired ethernet adapter 
#                   is known by the system
#
check_ethdevice() {
    return_code=${SUCCESS}
    this_device="${1}"

    if [ "${2}" != "" ]; then
        identifier="${2}"
    else
        identifier="wired"
    fi

    if [ "${this_device}" != "" ]; then
        printf "%-73s" "    Validating ${identifier} ethernet device ${this_device} ... "
        let nic_check=`ifconfig ${this_device} 2> /dev/null | awk '{print $1}' | egrep -c "^${this_device}$"`

        if [ ${nic_check} -gt 0 ]; then
            echo "SUCCESS"
        else
            echo "FAILED"
            err_msg="Invalid ${identifier} ethernet device \"${this_device}\""
            return_code=${ERROR}
        fi

    else
        err_msg="No ${identifier} ethernet device specified"
        return_code=${ERROR}
    fi

    return ${return_code}
}

#
#-------------------------------------------------------------------------------
#
# check_wethdevice - a subroutine to confirm that a given wireless ethernet 
#                    adapter is known by the system
#
check_wethdevice() {
    return_code=${SUCCESS}
    this_device="${1}"

    if [ "${2}" != "" ]; then
        identifier="${2}"
    else
        identifier="wireless"
    fi

    if [ "${this_device}" != "" ]; then
        printf "%-73s" "    Validating ${identifier} ethernet device ${this_device} ... "
        let nic_check=`iw dev "${this_device}" info 2> /dev/null | egrep -c "wiphy"`

        if [ ${nic_check} -gt 0 ]; then
            echo "SUCCESS"
        else
            echo "FAILED"
            err_msg="Invalid ${identifier} ethernet device \"${this_device}\""
            return_code=${ERROR}
        fi

    else
        err_msg="No ${identifier} ethernet device specified"
        return_code=${ERROR}
    fi

    return ${return_code}
}

#
#-------------------------------------------------------------------------------
#
# find_physdev - a subroutine to map a wireless ethernet device to the physical
#                radio known by the system
#
find_physdev() {
    return_code=${SUCCESS}
    this_device="${1}"

    if [ "${this_device}" != "" ]; then
        identifier="wireless"
        echo -ne "Mapping ${identifier} ethernet device ${this_device} to physical radio device: "
        radio_index=`iw dev "${this_device}" info 2> /dev/null | egrep -i "wiphy" | awk '{print $NF}'`

        if [ "${radio_index}" != "" ]; then
            radio_device="phy${radio_index}"
            echo "${radio_device}"
        else
            echo "FAILED"
            err_msg="Invalid ${identifier} ethernet device \"${this_device}\""
            return_code=${ERROR}
        fi

    else
        err_msg="No ${identifier} ethernet device specified"
        return_code=${ERROR}
    fi

    return ${return_code}
}


#
#-------------------------------------------------------------------------------
#
# check_wfreq - a subroutine to confirm that a given wireless frequency corridor
#               is known by a given wireless device
#
check_wfreq() {
    return_code=${SUCCESS}
    this_device="${1}"
    this_freq="${2}"
    this_channel="${3}"
    identifier="radio"

    # Make sure the frequency corridor provided is valid for this radio device
    if [ "${this_device}" != "" -a "${this_freq}" != "" -a "${this_channel}" != "" ]; then
        printf "%-73s" "    Verifying ${identifier} frequency corridor ... "
        err_msg="Invalid frequency for physical ${identifier} device ${this_device}"
        return_code=${ERROR}

        case ${this_freq} in

            HT20)
                echo "SUCCESS"
                err_msg=""
                return_code=${SUCCESS}
            ;;

            HT40+)

                if [ ${this_channel} -lt ${highest_channel} ]; then
                    echo "SUCCESS"
                    err_msg=""
                    return_code=${SUCCESS}
                else
                    echo "FAILED"
                fi

            ;;

            HT40-)

                if [ ${this_channel} -gt ${lowest_channel} ]; then
                    echo "SUCCESS"
                    err_msg=""
                    return_code=${SUCCESS}
                else
                    echo "FAILED"
                fi

            ;;

            *)
                echo "FAILED"
            ;;

        esac

    else
        err_msg="Must have ${identifier} device, frequency, and channel specified"
        return_code=${ERROR}
    fi

    return ${return_code}
}

#
#-------------------------------------------------------------------------------
#
# check_wchannel - a subroutine to confirm that a given wireless channel is 
#                  known by a given wireless device
#
check_wchannel() {
    return_code=${SUCCESS}
    this_device="${1}"
    this_channel="${2}"
    identifier="radio"

    # Make sure the channel provided is valid for this radio device
    if [ "${this_device}" != "" -a "${this_channel}" != "" ]; then
        printf "%-73s" "    Verifying ${identifier} channel ... "
        err_msg="Invalid channel for physical ${identifier} device ${this_device}"
        return_code=${ERROR}
        my_channels=`iw phy ${this_device} info 2> /dev/null | egrep "\[[0-9]*\]" | egrep -v "\(disabled\)" | awk '{print $4}' | sed -e 's/\[//g' -e 's/\]//g' | sort -un`
        lowest_channel=`echo ${my_channels} | awk '{print $1}'`
        highest_channel=`echo ${my_channels} | awk '{print $NF}'`

        for my_channel in ${my_channels} ; do
            let channel_check=`echo "${my_channel}" | egrep -c "^${this_channel}$"`

            if [ ${channel_check} -eq 1 ]; then
                echo "SUCCESS"
                err_msg=""
                return_code=${SUCCESS}
                break
            fi

        done

        if [ ${return_code} -ne ${SUCCESS} ]; then
            echo "FAILED"
        fi

    else
        err_msg="No ${identifier} device and channel specified"
        return_code=${ERROR}
    fi

    return ${return_code}
}

#
#-------------------------------------------------------------------------------
#
# make_mesh - a subroutine to construct a mesh interface against a given radio
#             device
#
make_mesh() {
    return_code=${SUCCESS}

    # Attempt to construct a mesh with the parameters from the config file
    if [ ${return_code} -eq ${SUCCESS} ]; then

        if [ "${mesh}" = "yes" -a "${mesh_dev}" != "" -a "${mesh_id}" != "" -a "${mesh_channel}" != "" -a "${mesh_frequency}" != "" ]; then
            echo "Preparing to create a new wireless mesh interface"

            # Make sure we have a valid wireless ethernet device
            check_wethdevice "${mesh_dev}"
            return_code=${?}

            # Figure out our actual physical device
            if [ ${return_code} -eq ${SUCCESS} ]; then
                echo -ne "    " && find_physdev "${mesh_dev}"
                return_code=${?}

                if [ ${return_code} -eq ${SUCCESS} ]; then
                    mesh_phy="${radio_device}"
                fi

            fi

            # Make sure this device actually supports the interface mode "mesh point"
            if [ ${return_code} -eq ${SUCCESS} ]; then
                let mp_check=`iw phy ${mesh_phy} info | egrep -c "mesh point$"`
 
                if [ ${mp_check} -eq 0 ]; then
                    err_msg="Wireless radio device ${meshphy} (${mesh_dev}) does not support mesh point mode"
                    return_code=${ERROR}
                fi

            fi

            # Make sure the channel provided is valid for this radio device
            if [ ${return_code} -eq ${SUCCESS} ]; then
                check_wchannel "${mesh_phy}" "${mesh_channel}"
                return_code=${?}
            fi

            # Make sure the frequency provided is valid for this radio device
            if [ ${return_code} -eq ${SUCCESS} ]; then
                check_wfreq "${mesh_phy}" "${mesh_frequency}" "${mesh_channel}"
                return_code=${?}
            fi

            # If we were passed an IP address, then make sure our mesh IP is a 
            # valid IPv4 address
            if [ ${return_code} -eq ${SUCCESS} ]; then

                if [ "${mesh_ip}" != "" ]; then
                    check_ipaddr "${mesh_ip}"
                    return_code=${?}
                fi

            fi

            # If we were not passed a mesh_if, then figure out our next available 
            # enumerated mesh interface
            if [ ${return_code} -eq ${SUCCESS} ]; then

                if [ "${mesh_if}" = "" ]; then
                    echo -ne "    Calculating next mesh interface index: "
                    mesh_if=""
                    meshcount=0

                    while [ "${mesh_if}" = "" ] ;do
                        let mesh_check=`iw dev mesh${meshcount} info 2> /dev/null | egrep -c "^Interface mesh${meshcount}$"`

                        if [ ${mesh_check} -eq 0 ]; then
                            mesh_if="mesh${meshcount}"
                            echo "${mesh_if}"
                        else
                            let meshcount=${meshcount}+1
                        fi

                    done

                fi

            fi

            # If we get here, then create the ${mesh_if} interface
            if [ ${return_code} -eq ${SUCCESS} ]; then
                printf "%-73s" "    Instantiating ${mesh_if} on physical radio device ${mesh_phy} ... "
                iw phy ${mesh_phy} interface add ${mesh_if} type mp mesh_id ${mesh_id}

                if [ ${?} -eq ${SUCCESS} ]; then
                    echo "SUCCESS"
                else
                    echo "FAILED"
                    let return_code=${return_code}+${?}
                fi

                sleep 2

                if [ ${return_code} -ne ${SUCCESS} ]; then
                    err_msg="Failed to create mesh interface ${mesh0} on physical radio device ${mesh_phy}"
                fi

            fi

            # If we get here, then set the channel and frequency corridor
            if [ ${return_code} -eq ${SUCCESS} ]; then
                printf "%-73s" "    Setting up ${mesh_if} on physical radio device ${mesh_phy} ... "
                iw dev ${mesh_if} set channel ${mesh_channel} ${mesh_frequency}

                if [ ${?} -eq ${SUCCESS} ]; then
                    echo "SUCCESS"
                else
                    echo "FAILED"
                    let return_code=${return_code}+1
                fi

                if [ ${return_code} -ne ${SUCCESS} ]; then
                    err_msg="Failed to set channel and frequency corridor on mesh interface ${mesh0} on physical radio device ${mesh_phy}"
                fi

            fi

            # If we get here, then bring up the mesh interface just created and configured
            if [ ${return_code} -eq ${SUCCESS} ]; then
                printf "%-73s" "    Bringing ${mesh_if} online ... "
                ifconfig ${mesh_dev} down > /dev/null 2>&1 && ifconfig ${mesh_if} up > /dev/null 2>&1

                if [ ${?} -eq 0 ]; then
                    echo "SUCCESS"
                else
                    echo "FAILED"
                    let return_code=${return_code}+1
                fi

                sleep 2

                if [ ${return_code} -ne ${SUCCESS} ]; then
                    err_msg="Failed to activate mesh interface ${mesh0} on physical radio device ${mesh_phy}"
                fi

            fi

            # If we get here and were provided with an IP address, then set it
            if [ ${return_code} -eq ${SUCCESS} ]; then

                if [ "${mesh_ip}" != "" ]; then
                    printf "%-73s" "    Assigning IP address ${mesh_ip} to ${mesh_if} ... "
                    ifconfig ${mesh_if} ${mesh_ip}

                    if [ ${?} -eq 0 ]; then
                        echo "SUCCESS"
                    else
                        echo "FAILED"
                        let return_code=${return_code}+1
                    fi

                    if [ ${return_code} -ne ${SUCCESS} ]; then
                        err_msg="Failed to assign IP address ${mesh_ip} to mesh interface ${mesh0} on physical radio device ${mesh_phy}"
                    fi

                fi

            fi

        fi

    fi

    return ${return_code}
}

#
#-------------------------------------------------------------------------------
#
# make_bridge - a subroutine to construct a bridge interface against a given 
#               set of ethernet devices
#
make_bridge() {
    return_code=${SUCCESS}

    # Attempt to construct a bridge from the parameters in the config file
    if [ ${return_code} -eq ${SUCCESS} ]; then

        if [ "${bridge}" = "yes" ]; then
            echo "Preparing to activate new ethernet bridge"

            # Figure out our next available enumerated bridge interface
            if [ "${bridge_if}" = "" ]; then
                echo "    Calculating next bridge index: "    
                bridge_if=""
                bridgecount=0

                while [ "${bridge_if}" = "" ] ;do
                    let bridge_check=`ifconfig bridge${bridgecount} 2> /dev/null | awk '{print $1}' | egrep -c "^bridge${bridgecount}"`

                    if [ ${bridge_check} -eq 0 ]; then
                        bridge_if="bridge${bridgecount}"
                    else
                        let bridgecount=${bridgecount}+1
                    fi

                done

            fi

            # Add mesh_if to bridge_nics
            bridge_nics=`echo -ne "${bridge_nics} ${mesh_if}\n" | sed -e 's/\ /\n/g' | sort -u`

            # Make sure the defined bridge_nics are valid
            for bridge_nic in ${bridge_nics} ; do
                check_ethdevice "${bridge_nic}" "bridge member"
                let return_code=${return_code}+${?}
            done

            # If we get here, then we can make a bridge 
            if [ ${return_code} -eq ${SUCCESS} ]; then
                printf "%-73s" "    Creating ethernet bridge ${bridge_if} ... "
                brctl addbr ${bridge_if}

                if [ ${?} -eq 0 ]; then
                    echo "SUCCESS"
                else
                    echo "FAILED"
                    let return_code=${return_code}+1
                fi

                sleep 2
       
                if [ ${return_code} -ne ${SUCCESS} ]; then
                    err_msg="Failed to create bridge device ${bridge_if}"
                fi

            else
                err_msg="At least one of the following network interfaces listed for bridging are invalid: ${bridge_nics}"
            fi

            # If we get here, then we can assign nics to the newly created bridge 
            if [ ${return_code} -eq ${SUCCESS} ]; then

                for bridge_nic in ${bridge_nics} ; do
                    printf "%-73s" "    Adding ethernet adapter ${bridge_nic} to bridge ${bridge_if} ... "
                    brctl addif ${bridge_if} ${bridge_nic}

                    if [ ${?} -eq 0 ]; then
                        echo "SUCCESS"
                    else
                        echo "FAILED"
                        let return_code=${return_code}+1
                    fi

                    sleep 2
                done

                if [ ${return_code} -ne ${SUCCESS} ]; then
                    err_msg="Failed to add one or more of the following network interfaces to bridge ${bridge_if}: ${bridge_nics}"
                fi

            fi

            # If we were passed an IP address, then make sure our bridge IP is a 
            # valid IPv4 address
            if [ ${return_code} -eq ${SUCCESS} ]; then

                if [ "${bridge_ip}" != "" ]; then
                    check_ipaddr "${bridge_ip}"
                    return_code=${?}

                    if [ ${return_code} -eq ${SUCCESS} ]; then
                        printf "%-73s" "    Assigning IP address ${bridge_ip} to ${bridge_if} ... "
                        ifconfig ${bridge_if} ${bridge_ip}

                        if [ ${?} -eq 0 ]; then
                            echo "SUCCESS"
                        else
                            echo "FAILED"
                            let return_code=${return_code}+1
                        fi

                        if [ ${return_code} -ne ${SUCCESS} ]; then
                            err_msg="Failed to assign IP address \"${bridge_ip}\" to bridge interface \"${bridge_if}\""
                        fi

                    fi

                fi

            fi
                
            # If we get here, then bring up the interface
            if [ ${return_code} -eq ${SUCCESS} ]; then
                printf "%-73s" "    Bringing ${bridge_if} online ... "
                ifconfig ${bridge_if} up

                if [ ${?} -eq 0 ]; then
                    echo "SUCCESS"
                else
                    echo "FAILED"
                    let return_code=${return_code}+1
                fi

                if [ ${return_code} -ne ${SUCCESS} ]; then
                    err_msg="Failed to activate bridge interface \"${bridge_if}\""
                fi
            fi

        else
            err_msg="No network devices listed for bridging"
            return_code=${ERROR}
        fi

    fi

    return ${return_code}
}

#
#-------------------------------------------------------------------------------
#
# make_hostapd - a subroutine to construct a hostapd configuration and then
#                start hostapd services
#
make_hostapd() {
    return_code=${SUCCESS}

    # Attempt to establish the hostapd service using the parameters from the 
    # config file
    if [ ${return_code} -eq ${SUCCESS} ]; then

        if [ "${hostapd}" = "yes" -a "${hostapd_if}" != "" -a "${hostapd_ssid}" != "" -a "${hostapd_channel}" != "" -a "${hostapd_passphrase}" != "" ]; then
            echo "Preparing to activate hostapd services"

            # Make sure we have a valid wireless ethernet device
            check_wethdevice "${hostapd_if}" "AP service"
            return_code=${?}

            # Figure out our actual physical device
            if [ ${return_code} -eq ${SUCCESS} ]; then
                echo -ne "    " && find_physdev "${hostapd_if}"
                return_code=${?}

                if [ ${return_code} -eq ${SUCCESS} ]; then
                    hostapd_phy="${radio_device}"
                fi

            fi

            # Make sure the wireless channel is valid
            if [ ${return_code} -eq ${SUCCESS} ]; then
                check_wchannel "${hostapd_phy}" "${hostapd_channel}"
                return_code=${?}
            fi

            # Augment hostapd config file
            if [ ${return_code} -eq ${SUCCESS} ]; then
                my_hostapd=`which hostapd 2> /dev/null`

                if [ "${my_hostapd}" != "" ]; then

                    if [ -e "${conf_dir}/hostapd.conf" ]; then

                        # Modify an existing hostapd config file
                        sed -i -e "s/^interface=.*$/interface=${hostapd_if}/g" "${conf_dir}/hostapd.conf"
                        sed -i -e "s/^ssid=.*$/ssid=${hostapd_ssid}/g" "${conf_dir}/hostapd.conf"
                        sed -i -e "s/^ignore_broadcast_ssid=.*$/ignore_broadcast_ssid=${hostapd_ssid}/g" "${conf_dir}/hostapd.conf"
                        sed -i -e "s/^channel=.*$/channel=${hostapd_channel}/g" "${conf_dir}/hostapd.conf"
                        sed -i -e "s/^wpa_passphrase=.*$/wpa_passphrase=${hostapd_passphrase}/g" "${conf_dir}/hostapd.conf"

                        if [ "${hostapd_hwmode}" != "" ]; then
                            sed -i -e "s/^hw_mode=.*$/hw_mode=${hostapd_hwmode}/g" "${conf_dir}/hostapd.conf"
                        fi

                    else

                        # Create a new hostapd config file
                        if [ "${hostapd_hwmode}" = "" ]; then
                            hostapd_hwmode="g"
                        fi
                        
                        echo "interface=${hostapd_if}"                > "${conf_dir}/hostapd.conf"
                        echo "driver=nl80211"                        >> "${conf_dir}/hostapd.conf"
                        echo "ssid=${hostapd_ssid}"                  >> "${conf_dir}/hostapd.conf"
                        echo "hw_mode=${hostapd_hwmode}"             >> "${conf_dir}/hostapd.conf"
                        echo "channel=${hostapd_channel}"            >> "${conf_dir}/hostapd.conf"
                        echo "macaddr_acl=0"                         >> "${conf_dir}/hostapd.conf"
                        echo "auth_algs=1"                           >> "${conf_dir}/hostapd.conf"
                        echo "ignore_broadcast_ssid=${hostapd_ssid}" >> "${conf_dir}/hostapd.conf"
                        echo "wpa=3"                                 >> "${conf_dir}/hostapd.conf"
                        echo "wpa_passphrase=${hostapd_passphrase}"  >> "${conf_dir}/hostapd.conf"
                        echo "wpa_key_mgmt=WPA-PSK"                  >> "${conf_dir}/hostapd.conf"
                        echo "wpa_pairwise=TKIP"                     >> "${conf_dir}/hostapd.conf"
                        echo "rsn_pairwise=CCMP"                     >> "${conf_dir}/hostapd.conf"
                    fi

                    # Try to start the hostapd service using our augmented config file
                    printf "%-73s" "    Starting hostapd services ... "

                    case ${is_busybox} in

                        0)
                            nohup ${my_hostapd} -B "${conf_dir}/hostapd.conf" > /dev/null 2>&1 &
                        ;;

                        *)
                            ${my_hostapd} -B "${conf_dir}/hostapd.conf" > /dev/null 2>&1 &
                        ;;

                    esac

                    sleep 2
                    let hostapd_check=`${my_ps} | egrep "hostapd" | egrep -v grep | wc -l`

                    if [ ${hostapd_check} -eq 0 ]; then
                        echo "FAILED"
                        err_msg="    Failed to start hostapd services"
                        return_code=${ERROR}
                    else
                        echo "SUCCESS"

                        # Add this interface to the bridge
                        if [ "${bridge}" = "yes" -a "${hostapd_if}" != "" ]; then

                            # Make sure we aren't already there, or that we aren't trying to add
                            # the bridge interface to itself
                            let element_check=`brctl show | egrep -c "${hostapd_if}"`

                            if [ ${element_check} -eq 0 ]; then
                                printf "%-73s" "    Adding ethernet adapter ${hostapd_if} to bridge ${bridge_if} ... "
                                brctl addif ${bridge_if} ${hostapd_if}

                                if [ ${?} -eq 0 ]; then
                                    echo "SUCCESS"
                                else
                                    echo "FAILED"
                                    let return_code=${return_code}+1
                                fi

                                if [ ${return_code} -ne ${SUCCESS} ]; then
                                    err_msg="Failed to add ethernet adapter ${hostapd_if} to bridge ${bridge_if}"
                                fi

                            fi

                        fi

                    fi

                else
                    err_msg="Could not find the hostapd command"
                    return_code=${ERROR}
                fi

            fi

        fi

    fi

    return ${return_code}
}

#
#-------------------------------------------------------------------------------
#
# make_dnsmasq - a subroutine to construct a dnsmasq configuration and then
#                start dnsmasq services
#
make_dnsmasq() {
    return_code=${SUCCESS}

    # Attempt to establish the dnsmasq service using the parameters from the 
    # config file
    if [ ${return_code} -eq ${SUCCESS} ]; then

        if [ "${dnsmasq}" = "yes" -a "${dnsmasq_if}" != "" -a "${dnsmasq_min_ip}" != "" -a "${dnsmasq_max_ip}" != "" ]; then
            echo "Preparing to activate dnsmasq services"

            # Validate our ethernet device
            check_ethdevice "${dnsmasq_if}" "DHCP service"
            return_code=${?}

            # Assuming a Class C subnet, make sure our min and max IP numbers 
            # are not out of range
            if [ ${return_code} -eq ${SUCCESS} ]; then

                if [ ${dnsmasq_min_ip} -le 0 -o ${dnsmasq_max_ip} -gt 254 ]; then
                    err_msg="One or more DHCP range numbers are out of bounds"
                    return_code=${ERROR}
                fi

            fi

            # Find our first three octets (assumes a Class C subnet)
            if [ ${return_code} -eq ${SUCCESS} ]; then

                if [ "${dnsmasq_ip}" = "" ]; then
                    dnsmasq_ip=`ifconfig "${dnsmasq_if}" | egrep "inet addr:" | awk '{print $2}' | awk -F':' '{print $NF}'`

                    if [ "${dnsmasq_ip}" = "" ]; then
                        err_msg="Cannot find an IP address from which to determine a DHCP range"
                        return_code=${ERROR}
                    fi

                else
                    check_ipaddr "${dnsmasq_ip}"
                    return_code=${?}
                fi

            fi

            # Find our first three octets (assumes a Class C subnet)
            if [ ${return_code} -eq ${SUCCESS} ]; then
                first_octet=`echo "${dnsmasq_ip}" | awk -F'.' '{print $1}'`
                second_octet=`echo "${dnsmasq_ip}" | awk -F'.' '{print $2}'`
                third_octet=`echo "${dnsmasq_ip}" | awk -F'.' '{print $3}'`

                # Set a usefule default leasetime if it isn't defined in the config file
                if [ "${dnsmasq_leasetime}" = "" ]; then
                    dnsmasq_leasetime="12h"
                fi

                my_dnsmasq=`which dnsmasq 2> /dev/null`

                if [ "${my_dnsmasq}" != "" ]; then

                    if [ -e "${conf_dir}/dnsmasq.conf" ]; then

                        # Modify an existing dnsmasq config file
                        sed -i -e "s/^dhcp-range=.*$/dhcp-range=${dnsmasq_if},${first_octet}.${second_octet}.${third_octet}.${dnsmasq_min_ip},${first_octet}.${second_octet}.${third_octet}.${dnsmasq_max_ip},${dnsmasq_leasetime}/g" "${conf_dir}/dnsmasq.conf"
                    else

                        # Create a new dnsmasq config file
                        echo "dhcp-range=${dnsmasq_if},${first_octet}.${second_octet}.${third_octet}.${dnsmasq_min_ip},${first_octet}.${second_octet}.${third_octet}.${dnsmasq_max_ip},${dnsmasq_leasetime}" >> "${conf_dir}/dnsmasq.conf"
                        echo "dhcp-leasefile=/tmp/dhcp.leases"                                                                                                                                                     >> "${conf_dir}/dnsmasq.conf"
                    fi

                    # Try to start the dnsmasq service using our augmented config file
                    printf "%-73s" "    Starting dnsmasq services ... "

                    case ${is_busybox} in

                        0)
                            nohup ${my_dnsmasq} -C "${conf_dir}/dnsmasq.conf" > /dev/null 2>&1 &
                        ;;

                        *)
                            ${my_dnsmasq} -C "${conf_dir}/dnsmasq.conf" > /dev/null 2>&1 &
                        ;;

                    esac

                    sleep 2
                    let dnsmasq_check=`${my_ps} | egrep "dnsmasq" | egrep -v grep | wc -l`

                    if [ ${dnsmasq_check} -eq 0 ]; then
                        echo "FAILED"
                        err_msg="    Failed to start dnsmasq services"
                        return_code=${ERROR}
                    else
                        echo "SUCCESS"

                        # Add this interface to the bridge
                        if [ "${bridge}" = "yes" -a "${dnsmasq_if}" != "" ]; then

                            # Make sure we aren't already there, or that we aren't trying to add
                            # the bridge interface to itself
                            let element_check=`brctl show | egrep -c "${dnsmasq_if}"`

                            if [ ${element_check} -eq 0 ]; then
                                printf "%-73s" "    Adding ethernet adapter ${dnsmasq_if} to bridge ${bridge_if} ... "
                                brctl addif ${bridge_if} ${hostapd_if}

                                if [ ${?} -eq 0 ]; then
                                    echo "SUCCESS"
                                else
                                    let return_code=${return_code}+1
                                fi

                                if [ ${return_code} -ne ${SUCCESS} ]; then
                                    err_msg="Failed to add ethernet adapter ${dnsmasq_if} to bridge ${bridge_if}"
                                fi

                            fi

                        fi

                    fi

                else
                    err_msg="Could not find the dnsmasq command"
                    return_code=${ERROR}
                fi

            fi

        fi

    fi

    return ${return_code}
}

################################################################################
# MAIN
################################################################################
#
# WHAT: Process our arguments
# WHY:  We must have them to continue
#
if [ ${exit_code} -eq ${SUCCESS} ]; then
    my_name=`basename "${0}"`
    conf_dir="/etc/meshbridge"
    config_file="meshbridge.conf"

    if [ ${#*} -ge 1 ]; then
        config_file=`basename "${1}"`
        config_dir=`dirname "${1}"`
        cwd=`pwd`
        cd "${config_dir}"
        conf_dir=`pwd`
        cd "${cwd}"
    fi

    if [ -d "${conf_dir}" -a -s "${conf_dir}/${config_file}" ]; then
        echo "Using configuration parameters from: \"${conf_dir}/${config_file}\""
        conf_file="${conf_dir}/${config_file}"
    else
        err_msg="Default config file \"${conf_dir}/${config_file}\" could not be found"
        exit_code=${ERROR}
    fi

fi

# WHAT: Process our config file
# WHY:  Asked to
#
if [ ${exit_code} -eq ${SUCCESS} ]; then
    get_config
    exit_code=${?}
fi

# WHAT: Disable hostapd if it is running
# WHY:  We are going to turn everything off, then bring only
#       those things that are wanted
#
if [ ${exit_code} -eq ${SUCCESS} ]; then
    kill_hostapd
    exit_code=${?}
fi

# WHAT: Disable dnsmasq if it is running
# WHY:  We are going to turn everything off, then bring only
#       those things that are wanted
#
if [ ${exit_code} -eq ${SUCCESS} ]; then
    kill_dnsmasq
    exit_code=${?}
fi

# WHAT: Find and remove any existing mesh interfaces
# WHY:  We want to take over the network config of this box in a way that does
#       not change the out of the box config.
#
if [ ${exit_code} -eq ${SUCCESS} ]; then
    flush_meshes
    exit_code=${?}
fi

# WHAT: Find and remove the members of all ethernet bridges
# WHY:  Same reason as that regarding meshes
#
if [ ${exit_code} -eq ${SUCCESS} ]; then
    flush_bridges
    exit_code=${?}
fi

# WHAT: Find and disable all network interface devices
# WHY:  Same reason as that regarding bridges
#
if [ ${exit_code} -eq ${SUCCESS} ]; then
    flush_nics
    exit_code=${?}
fi

# WHAT: Find and disable all network routes
# WHY:  Same reason as that regarding bridges and nics
#
if [ ${exit_code} -eq ${SUCCESS} ]; then
    flush_routes
    exit_code=${?}
fi

# WHAT: Build a mesh, provided the proper information
#       has been defined in the config file
# WHY:  A reason why we are here
#
if [ ${exit_code} -eq ${SUCCESS} ]; then
    make_mesh
    exit_code=${?}
fi

# WHAT: Build a bridge, provided the proper information
#       has been defined in the config file
# WHY:  Another reason why we are here
#
if [ ${exit_code} -eq ${SUCCESS} ]; then
    make_bridge
    exit_code=${?}
fi

# WHAT: Setup hostapd, provided the proper information
#       has been defined in the config file
# WHY:  Another reason why we are here
#
if [ ${exit_code} -eq ${SUCCESS} ]; then
    make_hostapd
    exit_code=${?}
fi

# WHAT: Setup dnsmasq, provided the proper information
#       has been defined in the config file
# WHY:  Another reason why we are here
#
if [ ${exit_code} -eq ${SUCCESS} ]; then
    make_dnsmasq
    exit_code=${?}
fi

# WHAT: Complain if necessary and exit
# WHY:  Success or failure, either way we are through
#
if [ ${exit_code} -ne ${SUCCESS} ]; then

    if [ "${err_msg}" != "" ]; then
        echo
        echo "    ERROR:  ${err_msg} ... processing halted"
        echo
    fi

fi

exit ${exit_code}
