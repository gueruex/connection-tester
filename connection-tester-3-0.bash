#!/usr/bin/env bash
declare -a ip_list=()
#Implement old features. Empty arg checking, arg validation, and start/stop IP functionality, output to file with date and preserve old. sort result
build_ip_list()
{
        cidr_bits=$(( 32 - "${subnet_cidr##*/}" ))
        ip_total=$(( 1 << cidr_bits ))
        IFS=.
        for octet in $network_id ; do
                hex_ip=${hex_ip}$(printf "%02x" "$octet")
        done 
        IFS=$' \t\n'

        for ((x=0; x<ip_total; x++)); do
                ip_list+=("$hex_ip")
                hex_ip=$(printf "%x" $(( 0x$hex_ip + 0x01 )))
        done
}


run_scan_unpriv(){
        # shellcheck disable=SC2016
        printf "%s\n" "${ip_list[@]}" | xargs -I {} -P 255 bash -c '
                ip_hex="{}"
                ip="$(( (0x$ip_hex >> 24) & 0xff )).$(( (0x$ip_hex >> 16) & 0xff )).$(( (0x$ip_hex >> 8) & 0xff )).$(( 0x$ip_hex & 0xff ))"
                timeout 1 bash -c "echo -n 2>/dev/null < /dev/tcp/${ip}/${scan_port} && echo $ip - [SUCCESS] Handshake made || echo $ip - [FAILURE] Handshake failed"
                [[ $? -ne 0 ]] && printf "%s - [TIMEOUT] No connection made\n" "$ip"


        ' > ip.tmp

        sort -t "." -k3,3n -k4,4n ip.tmp > ip_result_sorted.txt && rm ip.tmp #Change me later
}


main()
{       export scan_port=$scan_port
        build_ip_list
        run_scan_unpriv
}



args=$(2</dev/null getopt -a -o n:p:s: --long starting_ip:,ending_ip:,network_id:,port:,subnet_cidr:,version -- "$@") || {
        echo "An unsupported option was entered."
        exit 1
}

eval set -- "${args}"
while :
do
        # shellcheck disable=SC2178
        case $1 in
                     --starting_ip) starting_ip=$2; shift 2 ;;  # Not implemented yet
                       --ending_ip) ending_ip=$2; shift 2 ;;    # Not implemented yet
                -n |  --network_id) network_id=$2; shift 2 ;;
                -p |        --port) scan_port=$2; shift 2 ;;
                -s | --subnet_cidr) subnet_cidr=$2; shift 2 ;;
                         --version) echo "Version 3.0" ; exit 0 ;;
                                --) shift ; break ;;
        esac
done

main

exit 0