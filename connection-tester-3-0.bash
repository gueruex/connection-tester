#!/usr/bin/env bash

method=""
starting_ip=""
ending_ip=""
network_id=""
scan_port=""
subnet_cidr=""

#Implement old features. Arg validation, Preserve old output files
check_args()
{
        if [ -n "$starting_ip" -a -n "$ending_ip" ] ; then
                method=range
        elif [ -n "$network_id" -a -n "$subnet_cidr" ] ; then
                method=cidr;
        else
                read -rp "Please enter a Network ID: " network_id
                read -rp "Please enter a Subnet CIDR: " subnet_cidr
                method=cidr
        fi

        [ -z "$scan_port" ] && read -rp "Please enter a Port: " scan_port
}

ip_to_int()
{
        local ip=$1
        local IFS=.
        local hex_ip=""
        for octet in $ip ; do hex_ip=${hex_ip}$(printf "%02x" "$octet") ; done
        printf "%d" "0x$hex_ip"
}

build_ip_list_cidr()
{
        cidr_bits=$(( 32 - "${subnet_cidr##*/}" ))
        ip_total=$(( 1 << cidr_bits ))

        int_ip=$(ip_to_int "$network_id")

        for ((x=0; x<ip_total; x++, int_ip++)); do
                printf "%08x\n" "$int_ip"
        done | run_scan 
}

build_ip_list_range()
{
        int_start=$(ip_to_int "$starting_ip")
        int_end=$(ip_to_int "$ending_ip")

        for (( i=int_start; i<=int_end; i++)); do printf "%08x\n" "$i" ; done | run_scan 
}

run_scan(){
        xargs -I {} -P 256 bash -c '
                ip_hex="{}"
                ip="$(( (16#$ip_hex >> 24) & 0xff )).$(( (16#$ip_hex >> 16) & 0xff )).$(( (16#$ip_hex >> 8) & 0xff )).$(( 16#$ip_hex & 0xff ))"
                timeout 1 bash -c "echo -n 2>/dev/null < /dev/tcp/${ip}/${scan_port} && echo $ip - [SUCCESS] Handshake made || echo $ip - [FAILURE] Handshake failed"
                [[ $? -ne 0 ]] && printf "%s - [TIMEOUT] No connection made\n" "$ip"
        '
}


main()
{       export scan_port
        check_args

        [ -z "$method" ] && { printf "Method to build IP List could not be determined. Exiting." ; exit 1 ; }

        if [[ "cidr" == "$method" ]] ; then 
                build_ip_list_cidr
        elif [[ "range" == "$method" ]] ; then
                build_ip_list_range
        fi | sort -V -t "." -k3,3n -k4,4n
        
}



args=$(2</dev/null getopt -a -o n:p:s: --long starting-ip:,ending-ip:,network-id:,port:,subnet_cidr:,version -- "$@") || {
        echo "An unsupported option was entered."
        exit 1
}

eval set -- "${args}"
while :
do
        case $1 in
                     --starting-ip) starting_ip=$2; shift 2 ;;  # Not implemented yet
                       --ending-ip) ending_ip=$2; shift 2 ;;    # Not implemented yet
                -n |  --network-id) network_id=$2; shift 2 ;;
                -p |        --port) scan_port=$2; shift 2 ;;
                -s | --subnet_cidr) subnet_cidr=$2; shift 2 ;;
                         --version) echo "Version 3.0" ; exit 0 ;;
                                --) shift ; break ;;
        esac
done

main

exit 0