#!/usr/bin/env bash
# Scan pool for failed disks and light failure LED
# Should work with Supermicro SAS2 backplanes, unknown if it will work in other environments
# works with SAS2008 and Dell R720
# https://github.com/danb35/zpscan

# Possible failure conditions:
# -Unable to detect the correct LED if a failure happens before the first problem-free run after boot
# -Unable to light fault LED if controller cannot see the drive
# -Assumes drive serial numbers are unique in a system

SCRIPT_NAME=`basename "$0"`

pidfile=/var/run/$SCRIPT_NAME.pid
if [ -e $pidfile ]; then
    pid=`cat $pidfile`
    if kill -0 &>1 > /dev/null $pid; then
        echo "Already running"
        exit 1
    else
        rm $pidfile
    fi
fi
echo $$ > $pidfile

SYSTEM=$(uname)
if [ "$SYSTEM" = 'Linux' ]; then
    function CREATE_LOOKUP_FILE {
        local local_pool=$1
        
        blkid -s PARTUUID | awk -F  ":" '{split($1,drive,"/"); split($2,partuuid,"\""); print "s|"partuuid[2]"|"drive[3]"\t\t\t      |g"}' > /tmp/$SCRIPT_NAME-lookup-$local_pool.sed
    }
    
    function GET_DISK_SERIAL {
        local local_drive=$1
        
        hdparm -I /dev/$local_drive | grep 'Serial\ Number' | awk '{print $3 }'  | sed -E 's/^WD-//;s/[\t ]+//'
    }
    
    function SEND_MAIL {
        local local_mailbody=$1
        local local_mailsubject=$2
        local local_mailrecipient=$3
        
        if [ $mailauth == "true" ]; then
            echo "Mail authentication was enabled, will try to send it via ssmtp"
            
            if [ -z $( command -v ssmtp ) ]; then
                echo "ssmtp command not found, install it in path!"
                exit 1
            fi
            
            echo -e "Subject: $local_mailsubject \n\n $local_mailbody" | ssmtp $local_mailrecipient
            
        else
            echo "$local_mailbody" | mail -s "$local_mailsubject" $local_mailrecipient
        fi
    }
    
    elif [ "$SYSTEM" = 'FreeBSD' ]; then
    function CREATE_LOOKUP_FILE {
        local local_pool=$1
        
        glabel status | awk '{print "s|"$1"|"$3"\t\t\t      |g"}' > /tmp/$SCRIPT_NAME-lookup-$local_pool.sed
    }
    
    function GET_DISK_SERIAL {
        local local_drive=$1
        
        diskinfo -s /dev/$local_drive 2>/dev/null | sed -E 's/^WD-//;s/[\t ]+//'
    }
    
    function SEND_MAIL {
        local local_mailbody=$1
        local local_mailsubject=$2
        local local_mailrecipient=$3
        
        echo "$local_mailbody" | mail -s "$local_mailsubject" $local_mailrecipient
    }
else
    echo "Unsuported system"
    exit 1
fi

if [ ! "$1" ]; then
    echo "Usage: $SCRIPT_NAME pool [OPTION]"
    echo "Scan a pool, send email notification and activate leds of failed drives"
    echo ""
    echo "  -p,                        zfs pool to check"
    echo "  -m,                        mail TO address, default is root"
    echo "  -a,                        enable mail authentication"
    exit
fi

basedir="/root/.sas2ircu"
drivesfile=$basedir/drives-$pool
locsfile=$basedir/locs-$pool
if [ ! -d $basedir ]; then
    mkdir $basedir
fi
touch $drivesfile
touch $locsfile
mailauth=false
mailrecipient="root"

pools=()
OPTIND=1
while getopts "p:m:a" opt; do
    case $opt in
        p) pools+=("$OPTARG") ;;
        m) mailrecipient=${OPTARG} ;;
        a) mailauth=true ;;
        \?) ;; # Handle error: unknown option or missing required argument.
    esac
done
shift "$((OPTIND-1))"

if [ -z "$pools" ]; then
    echo 'Missing pool!' >&2
    exit 1
fi

for pool in ${pools[@]}
do
    echo "Working on pool - $pool"
    # Added exclude beacuse of false positive in case of pending ZFS features upgrade
    condition=$(zpool status $pool | egrep -i '(DEGRADED|FAULTED|OFFLINE|UNAVAIL|REMOVED|FAIL|DESTROYED|corrupt|cannot|unrecover)' | egrep -v '(features are unavailable)' )
    if [ "${condition}" ]; then
        CREATE_LOOKUP_FILE $pool
        emailSubject="`hostname` - ZFS pool - HEALTH fault"
        mailbody=$(zpool status $pool)
        echo "Sending email notification of degraded pool $pool"
        SEND_MAIL "$mailbody" "Degraded pool $pool on `hostname`" $mailrecipient
        drivelist=$(zpool status $pool | sed -f /tmp/$SCRIPT_NAME-lookup-$pool.sed | sed 's/p[0-9]//' | grep -E "(DEGRADED|FAULTED|OFFLINE|UNAVAIL|REMOVED|FAIL|DESTROYED)" | grep -vE "^\W+($pool|NAME|mirror|raidz|stripe|logs|spares|state)" | sed -E $'s/.*was \/dev\/([0-9a-z]+)/\\1/;s/^[\t  ]+([0-9a-z]+)[\t ]+.*$/\\1/')
        echo "Locating failed drives."
        for drive in $drivelist;
        do
            record=$(grep -E "^$drive" $drivesfile)
            controller=$(echo $record | cut -f 3 -d " ")
            encaddr=$(echo $record | cut -f 4 -d " ")
            echo Locating: $record
            sas2ircu $controller locate $encaddr ON
            # Add to list of enabled LEDs
            if [ $(egrep "$controller $encaddr" $locsfile | wc -c) -eq 0 ]; then
                echo $controller $encaddr >> $locsfile
            fi
        done
        rm /tmp/$SCRIPT_NAME-lookup-$pool.sed
    else
        echo "Saving drive list."
        CREATE_LOOKUP_FILE $pool
        drivelist=$(zpool status $pool | sed -f /tmp/$SCRIPT_NAME-lookup-$pool.sed | sed 's/p[0-9]//' | grep -E $'^\t  ' | grep -vE "^\W+($pool|NAME|mirror|raidz|stripe|logs|spares)" | sed -E $'s/^[\t ]+//;s/([a-z0-9]+).*/\\1/' )
        controllerlist=$(sas2ircu list | grep -E ' [0-9]+ ' | sed -E $'s/^[\t ]+//;s/([0-9]+).*/\\1/')
        printf "" > $drivesfile
        # Go through each controller and check if the drive is attached to that controller
        for controller in $controllerlist;
        do
            saslist=$(sas2ircu $controller display)
            for drive in $drivelist;
            do
                # "diskinfo -s disk" and "camcontrol identify [device id] -S" should be equivalent
                # WD disks have a WD- prefix that sas2ircu does not show, so we remove it
                serial=$( GET_DISK_SERIAL $drive )
                
                encaddr=$(echo "$saslist" | grep "$serial" -B 8 | sed -E '1!d;N;s/^.*: ([0-9]+)\n.*: ([0-9]+)/\1:\2/')
                # Add to list of mappings
                if [ "${encaddr}" ]; then
                    echo $drive $serial $controller $encaddr >> $drivesfile
                fi
            done
        done
        
        # Turn off all enabled LEDs
        while IFS= read -r loc;
        do
            controller=$(echo "$loc" | cut -f 1 -d " ")
            encaddr=$(echo "$loc" | cut -f 2 -d " ")
            sas2ircu $controller locate $encaddr OFF
        done < $locsfile
        printf "" > $locsfile
        rm /tmp/$SCRIPT_NAME-lookup-$pool.sed
    fi
done