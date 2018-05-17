#!/bin/bash
# shellcheck disable=SC1091,SC2068

# Optimise kernel parameters for running SAP ASE.
# The calculations are based on:
# - Various SAP notes.

cd /usr/lib/sapconf || exit 1
. util.sh
. common.sh

start() {
    log "--- Going to apply ASE tuning techniques"
    # Apply tuning techniques from 1275776 - Preparing SLES for SAP and 1984787 - Installation notes
    tune_preparation
    # SAP note 1557506 - Linux paging improvements
    tune_page_cache_limit
    # SAP note 1984787 - Installation notes
    tune_uuidd_socket

    # SAP note 1680803 - best practice
    source /etc/sysconfig/sapnote-1680803

    # SAP Note 2534844, bsc#874778
    save_value kernel.shmmni "$(sysctl -n kernel.shmmni)"
    chk_and_set_conf_val SHMMNI kernel.shmmni

    # set number of requests for block devices (sdX)
    for _dev in /sys/block/sd*; do
        [[ -e $_dev ]] || break  # if no sd block device exist
        _dev_save=${_dev//\//_}
        _nrreq=$(cat "$_dev"/queue/nr_requests)
        if [ -n "$_nrreq" ] && [ -n "$NRREQ" ]; then
            if [ "$_nrreq" -ne "$NRREQ" ]; then
                save_value "$_dev_save" "$_nrreq"
		echo "$NRREQ" > "$_dev"/queue/nr_requests
            fi
        fi
    done
    # set memlock for user sybase
    if [ "$MEMLOCK" == "0" ]; then
        # calculating memlock RAM in KB - 10%
        MEMSIZE_KB=$(grep MemTotal /proc/meminfo | awk '{print $2}')
        MEMLOCK=$( math "$MEMSIZE_KB - ($MEMSIZE_KB *10/100)" )
    fi
    ulimit_group=sybase
    for ulimit_type in soft hard; do
        sysconf_line="${ulimit_group} ${ulimit_type} memlock $MEMLOCK"
        limits_line=$(grep -E "^${ulimit_group}[[:space:]]+${ulimit_type}[[:space:]]+memlock+" /etc/security/limits.conf)
        save_limit=0
        if [ "$limits_line" ]; then
            save_limit=$(${limits_line##*[[:space:]]})
            sed -i "/$limits_line/d" /etc/security/limits.conf
        fi
        echo "$sysconf_line" >> /etc/security/limits.conf
        save_value "memlock_$ulimit_type" "$save_limit"
    done


    # 1410736
    save_value net.ipv4.tcp_keepalive_time "$(sysctl -n net.ipv4.tcp_keepalive_time)"
    chk_and_set_conf_val KEEPALIVETIME net.ipv4.tcp_keepalive_time
    save_value net.ipv4.tcp_keepalive_intvl "$(sysctl -n net.ipv4.tcp_keepalive_intvl)"
    chk_and_set_conf_val KEEPALIVEINTVL net.ipv4.tcp_keepalive_intvl

    # 1680803
    save_value fs.aio-max-nr "$(sysctl -n fs.aio-max-nr)"
    chk_and_set_conf_val AIOMAXNR fs.aio-max-nr
    save_value fs.file-max "$(sysctl -n fs.file-max)"
    chk_and_set_conf_val FILEMAX fs.file-max

    # Increase Linux autotuning TCP buffer limits
    # Set max to 16MB (16777216) for 1GE and 32M (33554432) or 54M (56623104) for 10GE
    # Don't set tcp_mem itself! Let the kernel scale it based on RAM.
    save_value net.core.rmem_max "$(sysctl -n net.core.rmem_max)"
    chk_and_set_conf_val RMEMMAX net.core.rmem_max
    save_value net.core.wmem_max "$(sysctl -n net.core.wmem_max)"
    chk_and_set_conf_val WMEMMAX net.core.wmem_max
    save_value net.core.rmem_default "$(sysctl -n net.core.rmem_default)"
    chk_and_set_conf_val RMEMDEF net.core.rmem_default
    save_value net.core.wmem_default "$(sysctl -n net.core.wmem_default)"
    chk_and_set_conf_val WMEMDEF net.core.wmem_default
    save_value net.core.netdev_max_backlog "$(sysctl -n net.core.netdev_max_backlog)"
    chk_and_set_conf_val NETDEVMAXBACKLOG net.core.netdev_max_backlog

    # If the server is a heavily used application server, e.g. a Database, it would
    # benefit significantly by using Huge Pages.
    # The default size of Huge Page in SLES is 2 MB, enabling Huge Pages would aid
    # in significant improvements for Memory Intensive Applications/Databases,
    # HPC Machines, this configuration needs to be done if the Applications support
    # Huge Pages. If the Applications do not support Huge Pages then configuring
    # Huge Pages would result in wastage of memory as it cannot be used any further
    # by the OS.
    save_value vm.nr_hugepages "$(sysctl -n vm.nr_hugepages)"
    chk_and_set_conf_val NUMBER_HUGEPAGES vm.nr_hugepages

    # The following parameters were specified in tuned.conf before 2017-07-25, but are removed from tuned.conf
    # because they are redundant or no formula exists to calculate them automatically:
    # vm.dirty_ratio = 10
    # vm.dirty_background_ratio = 3
    # kernel.sem = 1250 256000 100 8192
    # kernel.sched_min_granularity_ns = 10000000
    # kernel.sched_wakeup_granularity_ns = 15000000

    log "--- Finished application of ASE tuning techniques"
    return 0
}

stop() {
    log "--- Going to revert ASE tuned parameters"
    revert_preparation
    revert_page_cache_limit
    revert_uuidd_socket
    revert_shmmni

    val=$(restore_value net.ipv4.tcp_keepalive_time)
    [ "$val" ] && log "Restoring net.ipv4.tcp_keepalive_time=$val" && sysctl -w "net.ipv4.tcp_keepalive_time=$val"
    val=$(restore_value net.ipv4.tcp_keepalive_intvl)
    [ "$val" ] && log "Restoring net.ipv4.tcp_keepalive_intvl=$val" && sysctl -w "net.ipv4.tcp_keepalive_intvl=$val"

    val=$(restore_value fs.aio-max-nr)
    [ "$val" ] && log "Restoring fs.aio-max-nr=$val" && sysctl -w "fs.aio-max-nr=$val"
    val=$(restore_value fs.file-max)
    [ "$val" ] && log "Restoring fs.file-max=$val" && sysctl -w "fs.file-max=$val"


    val=$(restore_value net.core.rmem_max)
    [ "$val" ] && log "Restoring net.core.rmem_max=$val" && sysctl -w "net.core.rmem_max=$val"
    val=$(restore_value net.core.wmem_max)
    [ "$val" ] && log "Restoring net.core.wmem_max=$val" && sysctl -w "net.core.wmem_max=$val"
    val=$(restore_value net.core.rmem_default)
    [ "$val" ] && log "Restoring net.core.rmem_default=$val" && sysctl -w "net.core.rmem_default=$val"
    val=$(restore_value net.core.wmem_default)
    [ "$val" ] && log "Restoring net.core.wmem_default=$val" && sysctl -w "net.core.wmem_default=$val"
    val=$(restore_value net.core.netdev_max_backlog)
    [ "$val" ] && log "Restoring net.core.netdev_max_backlog=$val" && sysctl -w "net.core.netdev_max_backlog=$val"

    val=$(restore_value vm.nr_hugepages)
    [ "$val" ] && log "Restoring vm.nr_hugepages=$val" && sysctl -w "vm.nr_hugepages=$val"

    # Restore number of requests for block devices (sdX)
    #for _dev in `ls -d /sys/block/sd*`; do
    for _dev in /sys/block/sd*; do
        [[ -e $_dev ]] || break  # if no sd block device exist
        _dev_save=${_dev//\//_}
        NRREQ=$(restore_value "$_dev_save")
        [ "$NRREQ" ] && echo "$NRREQ" > "$_dev"/queue/nr_requests
    done

    # Restore memlock for user sybase
    ulimit_group=sybase
    for ulimit_type in soft hard; do
        MEMLOCK=$(restore_value memlock_$ulimit_type)
        restore_line="${ulimit_group} ${ulimit_type} memlock $MEMLOCK"
        limits_line=$(grep -E "^${ulimit_group}[[:space:]]+${ulimit_type}[[:space:]]+memlock+" /etc/security/limits.conf)
        if [ "$limits_line" ]; then
            sed -i "/$limits_line/d" /etc/security/limits.conf
        fi
        echo "$restore_line" >> /etc/security/limits.conf
    done

    log "--- Finished reverting ASE tuned parameters"
    return 0
}

process $@
