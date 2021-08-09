# zpscan.sh
This script is designed to notify you of disk failures on your TrueNAS CORE / TrueNAS SCALE server, and light the disk failure LED on your SuperMicro SAS2 backplane or SAS2008 with Dell R720.  It is unknown whether it will work with other manufacturers' backplanes.  It's unlikely this script will work as is in any environment other than a TrueNAS CORE and TrueNas SCALE.

# Installation
Download the script to someplace on your pool, and make it executable using `chmod +x zpscan.sh`.

# Usage
This script should be run as a regular cron job--the frequency is up to you, but I'd suggest between 15 minutes and an hour.  The command to run is `/path/to/zpscan.sh -p <poolname> -p <poolname> -m [email_address] -a`.  You can run with multiple pools defined. The email address is optional; if set, the script will email you on disk failure. The email authentication is optional; if set, will look at /etc/ssmtp/ssmtp.conf for configuration and send mail accordingly, currently supports only TrueNAS SCALE.

# Operation
The script runs regularly.  If the pool is healthy, it writes a text file to `/root/.sas2ircu/drives-<poolname>` listing your drives and their locations on your backplane.  If not, it writes a text file to `/root/.sas2ircu/locs-<poolname>` with the locations of any failed disks, turns on the warning LEDs for those locations, and (optionally) sends an email to the specified email address.

# Further Discussion
Further discussion can be directed to [this thread](https://forums.freenas.org/index.php?resources/disk-failure-leds-for-supermicro-sas-backplanes.74/) on the FreeNAS forums.