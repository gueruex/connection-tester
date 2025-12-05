#!/usr/bin/env bash

DEFAULT_PROTOCOL=tcp
DEFAULT_TIMEOUT=2
ORIGINAL_IFS=$IFS
octets=()
pid_tracker=()
declare -A error_levels

error_levels[info]=0
error_levels[warn]=1
error_levels[error]=2
error_levels[debug]=3

DEFAUT_GLOBAL_ERROR_LEVEL="${error_levels[error]}"

declare -g subnet_cidr

trap cleanup_helper EXIT

helpMenu(){ #Change this to use printf later. Will look 1000x better and be easier to format
    echo -e "
Script to do connection requests in an automated fashion in evironments where programs like nmap/netcat are prohibited.

Options:
    --starting_ip      : Overrides using the subnet_cidr for more fin grained control over the ip range. Use in connjunction with \"ending_ip\"
    --ending_ip        : Last IP to check when used with \"--starting_ip\"
    --protocol         : Set to TCP or UDP (TCP by default) **UDP Currently not implemented and will always show open.
    -n | --network_id  : Used to set network id of network to scan
    -p | --port        : Specify port(s) to be scanned. Supports single port, comma separarted, ranges, or a combination of any of the previous listed. (E.g -p 20-22,80,53,443,8080,8443,25000-25020)
    -s | --subnet_cidr : Specify CIDR to use (E.g /24)
    -t | --timeout     : Speciify timeout how long for connection to wait before timing out. (Default 2 seconds, 0 for no user defined timeout)
    -v | --verbosity   : Set verbosity level (0=info 1=warn 2=error 3=debug)
    -h | --help        : You are here now
    -v | --version     : Give script version

Info:
    If no \"connectionLog\" file is generated post-run it means no connections were able to be made before the timeout. You can increase the timeout if this happens, but if nothing was found after the default 2 seconds, there is probably no route."

}

cleanup_helper(){
    for pid in "${pid_tracker[@]}" ; do
        disown "$pid"
        [ -e "/proc/$pid/exe" ] && &>/dev/null kill -SIGUSR1 "$pid"
        console_logger "${error_levels[debug]}" "TIMEOUT: BG Process with PID: $pid killed"
    done
 }
 
console_logger(){
    #Custom console logger
    local yellow="\e[40;0;33m"
    local red="\e[40;0;31m"
    local green="\e[40;0;32m"
    local white="\e[40;0;37m"
    local clear="\e[0m"
    local prefix=""
    local error_level=${desired_error_level:-}
    local message_level=$1
    local message=$2
    
    case $message_level in
        0) prefix="${white}[INFO]${clear}" ;;
        1) prefix="${yellow}[WARN]${clear}" ;;
        2) prefix="${red}[ERROR]${clear}" ;;
        3) prefix="${green}[DEBUG]${clear}" ;;
    esac
    
    if [[ "$error_level" -ge "$message_level" ]] ; then
        echo -e "$(date +%H:%M%S) $prefix $message"
    fi
}
 
raise_error(){
    local error_code="$1"
    case "$error_level" in
        1101)
            local_var_name=$2
            console_logger "${error_levels[error]}" "$error_code : Variable \"$var_name\" has an invalid value."
            exit 1
            ;;
        1102)
            local port_number=$2
            console_logger "${error_levels[error]}" "$error_code : An invalid port \"$port_number\" has been entered. Skipping invalid port."
            ;;
    esac
}

validate_vars(){
    local var_to_validate="$1"
        case "$var_to_validate" in
            "protocol")
                local protocol="${2,,}"
                { [[ "$protocol" =~ ^(udp|tcp)$ ]] && echo "$protocol" ; } || return 1
                ;;
            "ip")
                local ip="$2"
                { [[ "$ip" =~ ^([0-9]{1,3}.){3}[0-9]{1,3}$ ]] && return 0 ; } || return 1
                ;;
            "subnet_cidr")
                local subnet_cidr="$2"
                
                { { [[ "$subnet_cidr" =~ ^[0-9]{2} ]] && [[ "$subnet_cidr" -ge 16 ]] && [[ "$subnet_cidr" -le 32 ]] ; } && return 0 ; } || return 1
                ;;
            "port")
                local port_start="$2"
                local port_end="$3"
                { { [[ "$port_start" =~ ^[0-9]{1,5}$ ]] && [[ "$port_end" =~ ^[0-9]{1,5}$ ]] && [[ "$port_start" -ge 1 ]] 2>/dev/null && [[ "$port_end" -le 65535 ]] 2>/dev/null && [[ "$port_start" -le "$port_end" ]] 2>/dev/null ; } && return 0 ; } || return 1
                ;;
            esac
}

get_start_end_ip(){
    #Converts starting ip and cidr to binary then adds them together to get ending ip
    local cidr_bit cidr_to_binary
    
    cidr_bit=$(( 2**( 32 - "$subnet_cidr" ) ))
    cidr_to_binary=$( bc <<< "obase=2; $cidr_bit" ) #Here we convert the given cidr (E.g 24) into binary (E.g 100000000)
    starting_ip_binary_32=$( printf "%032d\n" "$cidr_to_binary" ) #Then make sure it is in a 32 bit format
    
    while IFS='.' read -r oct_1 oct_2 oct_3 oct_4 ; do
        for num in {1..4} ; do #Loop through all 4 octets and convert them to binary
            declare -n octet=oct_$num
            declare "starting_octet_$num"="$octet"
            octet=$( bc <<< "obase=2; $octet" )
            starting_ip_binary+=$(printf "%08d\n" "$octet")
        done
    done <<< "$network_id"
    ending_ip_binary=$( printf "%032s\n" "$( bc <<< "obase=2; $(( 2#$starting_ip_binary + 2#$starting_ip_binary_32 -1 ))" )" | tr ' ' '0') #Then we calculate the ending ip binary by adding the starting ip with the amount of ips the cidr calls from
    
    for p in {0..3} ; do
        declare ending_octet_$(( p + 1 ))=$(( 2#${ending_ip_binary:$(( p * 8 )):8} ))
    done
    
    readarray -t octets < <(echo -e "$starting_octet_1\n$starting_octet_2\n$starting_octet_3\n$starting_octet_4\n$ending_octet_1\n$ending_octet_2\n$ending_octet_3\n$ending_octet_4")
    #Ugly solution, but it works. Echo all the octets into an array to return it via the lastpipe shell option
}

convert_cidr(){
    console_logger "${error_levels[info]}" "Validating Network id"
    #checks if net_id was explicitly set via a flag. If not prompt user to set one
    [[ -z "$network_id" ]] && read -rp "Network Id (E.g 192.168.0.0): " network_id
    #Then validate it
    validate_vars "ip" "$network_id" || raise_error 1101 "Network Id"
    
    
    console_logger "${error_levels[info]}" "Validating Subnet CIDR"
    #checks if CIDR was explicitly set via a flag. If not prompt user to set one
    [[ -z "$subnet_cidr" ]] && read -rp "Subnet Mask (I.e /24): " subnet_cidr
    #Remove any leading forward slash (/24 vs 24)
    subnet_cidr="${subnet_cidr##*/}"
    #Then validate it
    validate_vars "subnet_cidr" "$subnet_cidr" || raise_error 1101 "Subnet CIDR"
    
    get_start_end_ip
}

main(){
    shopt -s lastpipe
    protocol=${protocol:-"$DEFAULT_PROTOCOL"}
    console_logger "${error_levels[info]}" "Validating Protocol"
    protocol=$(validate_vars "protocol" "$protocol") || raise_error 1101 "protocol"
    
    
    #If either starting_ip or ending_ip were not set assume using net_id + cidr
    if [[ -z "$starting_ip" ]] || [[ -z "$ending_ip" ]] ; then
        convert_cidr
        starting_ip=("${octets[@]:0:4}")
        ending_ip=("${octets[@]:4:4}")
    else
    
    
        validate_vars "ip" "$starting_ip" || raise_error 1101 "starting_ip"
    
        validate_vars "ip" "$ending_ip" || raise_error 1101 "ending_ip"
    
    
    
    
    
        for ip in "starting_ip" "ending_ip" ; do #The most convuluted for loop ever. 0/10 readability :(
            while IFS=. read -r oct1 oct2 oct3 oct4 ; do
                eval "$ip=( \"oct1\" \"oct2\" \"oct3\" \"oct4\" )"
            done <<< "${!ip}"
        done
        
    fi
    
    [[ -z $port ]] && read -rp "Port: " port
    console_logger "${error_levels[info]}" "Validating Port(s)"
    
    IFS=','
    for portLoop in $port ; do
        local port_start port_end
        
        IFS=- read -r port_start port_end <<< "$portLoop" && port_end=${port_end:-$port_start}
        validate_vars "port" "$port_start" "$port_end" || { raise_error 1102 "$portLoop" ; continue ; }
        
        IFS=$ORIGINAL_IFS
        for port2scan in $(seq "$port_start" "$port_end") ; do
            [[ -f connectionLog_${port2scan} ]] && { f="connectionLog_${port2scan}" ; console_logger "${error_levels[info]}" "Archiving old scan \"$f\"" ; new_filename=old_${f}_$(openssl rand -hex 4) ; mv "$f" "$new_filename" ; }
            console_logger "${error_levels[info]}" "Scanning port $port2scan"
            loopThroughIps 1
        done
    done
    
    
    if [[ ! $timeout == "0" ]] || [[ -z $timeout ]] ; then
        sleep "${timeout:-$DEFAULT_TIMEOUT}"
        exit 0
    else
        wait
    fi
}

loopThroughIps(){
    
    
    local i=$1
    local starting_octet="${starting_ip[$(( i - 1 ))]}"
    local ending_octet="${ending_ip[$(( i - 1 ))]}"
    IFS=$ORIGINAL_IFS
    for oct in $(seq "$starting_octet" "$ending_octet") ; do
        if [[ ! $i -eq 4 ]] ; then
            loopThroughIps $(( i + 1 )) "${@:2}" "$oct"
        else
            local ip="$2.$3.$4.$oct"
            console_logger "${error_levels[debug]}" "Processing Ip: $ip"
            
            {
                trap 'echo "$ip - [TIMEOUT] No connection made" >> connectionLog_${port2scan} ; exit 0' SIGUSR1
                
                echo -n 2>/dev/null < "/dev/${protocol:-tcp}/${ip}/${port2scan}" && echo "$ip - [SUCCESS] Handshake made" >> "connectionLog_${port2scan}" || echo "$ip - [FAILURE] Handshake failed" >> "connectionLog_${port2scan}"
                console_logger "${error_levels[debug]}" "Ip finished: $ip"
            } &
            pid_tracker+=($!)
        fi
    done
}

args=$(2</dev/null getopt -a -o hp:s:n:t:v: --long starting_ip:,ending_ip:,port:,protocol:,subnet_cidr:,network_id:,tmeout:,verbosity:,version,help -- "$@") || {
    echo "An unsupported option was entered."
    exit 1
}

eval set -- "${args}"
while :
do
    case $1 in
        --starting_ip)      starting_ip=$2; shift 2 ;;
        --ending_ip)        ending_ip=$2; shift 2 ;;
        --protocol)         protocol=$2; shift 2 ;;
        -n | --network_id)  network_id=$2; shift 2 ;;
        -p | --port)        port=$2; shift 2 ;;
        -s | --subnet_cidr) subnet_cidr=$2; shift 2 ;;
        -t | --timeout)     timeout=$2; shift 2 ;;
        -v | --verbosity)   desired_error_level=$2; shift 2 ;;
             --version)     echo "Version 2.5" ; exit 0 ;;
        -h | --help)        helpMenu ; exit 0 ;;
        --)                 shift ; break ;;
    esac
done

main
