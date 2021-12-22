#!/bin/bash
echo " "
echo " "
echo "2021-DEC_22-1450
---------------------------------
---------------------------------
BETA
---------------------------------
---------------------------------

All-In-One Tool
No warrantys or gaurentees
Run at your own risk!!
https://github.com/mkolakowski/curl
---------------------------------
---------------------------------"

#To-do/WishList!!
# - Create bitwarden backup config system
# - Add version tracking to minecraft config(server version for bakcups

#//////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////
# Color  Variables

        green='\e[32m'
        blue='\e[34m'
        clear='\e[0m'

#//////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////
# Color Functions

ColorGreen(){
        echo -ne $green$1$clear
        } #End

ColorBlue(){
        echo -ne $blue$1$clear
        } #End

#//////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////
        
        
        MotdURL="https://raw.githubusercontent.com/mkolakowski/curl/main/01-custom-motd" #Motd Github URL
        
        #JAVA Server URLS
        JavaMinecraftServer_1_15_2="https://launcher.mojang.com/v1/objects/bb2b6b1aefcd70dfd1892149ac3a215f6c636b07/server.jar"
        JavaMinecraftServer_1_16_0="https://launcher.mojang.com/v1/objects/7361a24df069a06748844cc7483c35d4abd2d80c/server.jar"
        JavaMinecraftServer_1_16_2="https://launcher.mojang.com/v1/objects/c5f6fb23c3876461d46ec380421e42b289789530/server.jar"
        JavaMinecraftServer_1_16_5="https://launcher.mojang.com/v1/objects/1b557e7b033b583cd9f66746b7a9ab1ec1673ced/server.jar"
        
        #Java Minecraft Defaults
        JavaMinecraftServerLocation="/media/minecraft-java/server"
        JavaMinecraftConfigPath="$JavaMinecraftServerLocation/minecraft.config"
        JavaMinecraftBackupLocation="/media/minecraft-java/backup"
        JavaMinecraftRemoteBackupLocation="na"
        JavaMinecraftMemoryMax="1g"
        JavaMinecraftMemoryMin="512m"
        JavaMinecraftScreenSession="minecraft-java"
        JavaMinecraftJarURL=""
        JavaMinecraftServerURL=""
        JavaMinecraftServerVersion=""
        
        #Bitwarden Backup Variables
        BitwardenConfigPath="/media/bitwarden-backup/bitwarden.config"
        BitwardenServerLocation="./bwdata"
        BitwardenLocalBackupLocation="/media/bitwarden-backup/Full/"
        BitwardenRemoteBackupLocation="na"

#//////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////

        starttime=$(date +%Y%m%d-%H%M%S)
        startdate=$(date +%Y-%m-%d)

#//////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////


#First checks if Open JDK 8 is installed then will install if past test
function function_Ubuntu_Install () {

        echo "checking if $1 is installed"
        UbuntuAppName=$1
	sudo apt update
        Appinstallstatus=$(dpkg-query -W --showformat='${Status}\n' $UbuntuAppName 2>/dev/null)
        if [[ "${Appinstallstatus}" != "install ok installed" ]]; 
        then
                echo "-----------------------------"
                echo "Installing $UbuntuAppName"
                #Installing app

                if apt-get -qq install -y $UbuntuAppName >/dev/null; 
                then    
                        echo "$UbuntuAppName Install has now Completed"
                        dpkg-query -W --showformat='${Version}\n' $UbuntuAppName
                        echo "-----------------------------"
                fi
        else        
                echo "$UbuntuAppName Already Installed"
        fi
} 

# Installs Netdata using vendor provided scripts
function function_Install_Netdata () {
        bash <(curl -Ss https://my-netdata.io/kickstart.sh)
}

function function_Install_Geekbench5 () {
    curl -s  https://gitlab.com/mkolakowski/bench/raw/master/geekbench-5.sh | sudo bash
} 

# Adds the two 
function function_Tailscale_Install () {
        curl -fsSL https://pkgs.tailscale.com/stable/ubuntu/focal.gpg | sudo apt-key add -
	
        curl -fsSL https://pkgs.tailscale.com/stable/ubuntu/focal.list | sudo tee /etc/apt/sources.list.d/tailscale.list

        function_Ubuntu_Install "tailscale"

} 

#First checks if Open JDK 8 is installed then will install if past test
function function_install_OpenJDK () {
        function_Ubuntu_Install "openjdk-8-jre-headless"
} 

#Installs Fail2Ban then shows its status
function function_Install_Fail2Ban () {
        function_Ubuntu_Install "fail2ban"
        sudo systemctl status fail2ban
        sudo cp /etc/fail2ban/jail.{conf,local}   
} 

#Installs Repo Keys then installs application
function function_Install_PlexMediaServer () {
    sudo echo deb https://downloads.plex.tv/repo/deb public main | sudo tee /etc/apt/sources.list.d/plexmediaserver.list
    sudo curl https://downloads.plex.tv/plex-keys/PlexSign.key | sudo apt-key add -
    
    function_Ubuntu_Install "plexmediaserver"
} 

#First checks if Open JDK 8 is installed then will Remove if past test
function function_OpenJDK_8_Headless_Uninstall () {
        #checking if JAVA is installed
        javainstallstatus=$(dpkg-query -W --showformat='${Status}\n' openjdk-8-jre-headless 2>/dev/null)
        if [[ "${javainstallstatus}" = "install ok installed" ]]; 
        then
                echo "---------------------------"
                echo "Removing OpenJDK 8 Headless"
                #Installing Java
                apt remove openjdk-8-jre-headless -y
                echo "--------------------------------------"
                echo "Removal of OpenJDK 8 Headless Complete"                
        else
                echo "-----------------------"
                echo "OpenJDK 8 Not Installed"
        fi
} 

#//////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////

# Copies values from configuration into script
function function_Bitwarden_Load_Config () {

        #tells the program to refrence this file
        . $BitwardenConfigPath
        #Copies variables from file (on right side) to script variables
        BitwardenLocalBackupLocation=$confBitwardenBackupLocal
        BitwardenRemoteBackupLocation=$confBitwardenRemoteBackupLocation
        BitwardenServerLocation=$confBitwardenServerLocation
} 

#Creates Config file for the Java edition of Minecraft
function function_Bitwarden_Create_Config () {

        #Prints Echo with printed variables to path variable
        echo "Creating config at: $BitwardenConfigPath"
        echo "------------------"
        echo "
        confBitwardenServerLocation=$BitwardenServerLocation
        confBitwardenRemoteBackupLocation=$BitwardenRemoteBackupLocation
        confBitwardenBackupLocal=$BitwardenLocalBackupLocation

        " >> $BitwardenConfigPath
} 

# Will exit function if config exists, does not overwrite file
function function_Bitwarden_Build_Config() {

        function_Bitwarden_Load_Config
        #Checks if Config exists
        if [[ ! -f $BitwardenConfigPath ]]; 
        then   
                echo "Building Config"
                #Prints Path then Creates folder path then builds config with default values
                #echo $BitwardenConfigPath
                sudo mkdir -p $BitwardenLocalBackupLocation
                function_Bitwarden_Create_Config
                else
                        echo ""
                fi
} 

# Will exit function if config exists, WILL overwrite file USE WITH CAUTION
function function_Bitwarden_Rebuild_Config() {

        #Checks if Config exists
        if [[ $BitwardenConfigPath ]]; 
        then   
                #Prints Path then Creates folder path then builds config with default values
                echo "removing $BitwardenConfigPath"
                rm $BitwardenConfigPath
                else
                        echo "no config to remove"
                fi

        function_Bitwarden_Create_Config

} 

function function_Bitwarden_Backup () {

        function_Bitwarden_Load_Config

        echo ---------------------------------------------------------------------------
        echo Backup Database
                zip -r $BitwardenLocalBackupLocation/$startdate/bitwarden-full-$starttime.zip $BitwardenRemoteBackupLocation
        echo ---------------------------------------------------------------------------
        echo Uploading backup Zip - Gsuite
                rclone copy -P $BitwardenLocalBackupLocation $BitwardenRemoteBackupLocation/full/$(date +%Y-%m)/$(date +%d)
        echo ---------------------------------------------------------------------------
        echo Uploading mssql backups - Gsuite
                rclone copy -P $BitwardenServerLocation/mssql/backups $BitwardenRemoteBackupLocation/database
        echo ---------------------------------------------------------------------------
        #echo Deleting backup Zip
                #rm $BitwardenLocalBackupLocation
        #echo ---------------------------------------------------------------------------
                #echo Checking File System to see that backup zip was deleted
                #ls -l
} 

#//////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////

# Copies values from configuration into script
function function_Minecraft_Java_Load_Config () {

        #tells the program to refrence this file
        . $JavaMinecraftConfigPath
        #Copies variables from file (on right side) to script variables
        JavaMinecraftServerLocation=$confJavaMinecraftServerLocation
        JavaMinecraftBackupLocation=$confJavaMinecraftBackupLocation
        JavaMinecraftRemoteBackupLocation=$confJavaMinecraftRemoteBackupLocation
        JavaMinecraftMemoryMin=$confJavaMinecraftMemoryMin
        JavaMinecraftMemoryMax=$confJavaMinecraftMemoryMax
        JavaMinecraftServerVersion=$confJavaMinecraftServerVersion
} 

function function_Minecraft_Java_Backup_Config () {

        sudo mkdir -p $JavaMinecraftServerLocation/bakupConfig
        cp $JavaMinecraftConfigPath $JavaMinecraftServerLocation/bakupConfig/$JavaMinecraftServerVersion-$starttime.config
        echo " "
        echo "Backup Config located at: $JavaMinecraftServerLocation/bakupConfig/configbackup-$starttime.OLD"
        echo " "
} 

#Creates Config file for the Java edition of Minecraft
function function_Minecraft_Java_Create_Config () {

        #Prints Echo with printed variables to path variable
        echo "Creating config at: $JavaMinecraftConfigPath"
        echo "------------------"
        echo "
        # JavaMinecraftServerLocation - Location of Minecraft Directoty
                confJavaMinecraftServerLocation=$JavaMinecraftServerLocation
        # JavaMinecraftBackupLocation - Local Location Minecraft Backup to be placed
                confJavaMinecraftBackupLocation=$JavaMinecraftBackupLocation
        # JavaMinecraftRemoteBackupLocation - Rclone Location Minecraft Backup to be placed, Leave Blank if not using
                confJavaMinecraftRemoteBackupLocation=$JavaMinecraftRemoteBackupLocation
        # JavaMinecraftMemoryMin - Minimum memory used
                confJavaMinecraftMemoryMin=$JavaMinecraftMemoryMin
        # JavaMinecraftMemoryMax - Minimum memory used
                confJavaMinecraftMemoryMax=$JavaMinecraftMemoryMax
        # JavaMinecraftServerVersion - Lists version of server.jar
                confJavaMinecraftServerVersion=$JavaMinecraftServerVersion

        " >> $JavaMinecraftConfigPath
} 

#Starts up the Minecraft Server
function function_Minecraft_Java_Start_Server () {

        function_Minecraft_Java_Load_Config
        cd $JavaMinecraftServerLocation

        #starts a screen session with the established name and startup paremeters
        screen -d -m -S $JavaMinecraftScreenSession java -Xms$JavaMinecraftMemoryMin -Xmx$JavaMinecraftMemoryMax -jar $JavaMinecraftServerLocation/server.jar nogui

        echo "_____________________________________________"
        echo "Please give the server 30-60 seconds to start"
} 

#Opens Nano to edit EULA
function function_Minecraft_Connect () {

        function_Minecraft_Java_Load_Config

        screen -r $JavaMinecraftScreenSession
} 

#Stops the Minecraft Server
function function_Minecraft_Java_Stop_Server () {

        function_Minecraft_Java_Load_Config

        #sends Stopping Command to Screen Session
        screen -r $JavaMinecraftScreenSession -X stuff 'say Stoping server now\n'
        screen -r $JavaMinecraftScreenSession -X stuff 'stop\n'
        screen -r $JavaMinecraftScreenSession
} 

#Restarts the Java Minecraft Server
function function_Minecraft_Java_Restart_Server () {

        #Calls Stop then start functions
        function_Minecraft_Java_Stop_Server
        function_Minecraft_Java_Start_Server
} 

#Opens Nano to edit EULA
function function_Minecraft_Java_Edit_EULA () {
        
        function_Minecraft_Java_Load_Config

        nano $JavaMinecraftServerLocation/eula.txt
} 

#Opens Nano to edit EULA
function function_Minecraft_Java_Edit_Properties () {

        function_Minecraft_Java_Load_Config

        nano $JavaMinecraftServerLocation/server.properties
} 

# Builds the Java Minecraft run configs
# Will exit function if config exists, does not overwrite file
function function_Minecraft_Java_Build_Config() {

        function_Minecraft_Java_Load_Config
        #Checks if Config exists
        if [[ ! -f $JavaMinecraftConfigPath ]]; 
        then   
                echo "Building Config"
                #Prints Path then Creates folder path then builds config with default values
                #echo $JavaMinecraftConfigPath
                sudo mkdir -p $JavaMinecraftServerLocation
                function_Minecraft_Java_Create_Config
                else
                        echo ""
                fi
} 

# Builds the Java Minecraft run configs
# Will exit function if config exists, WILL overwrite file USE WITH CAUTION
function function_Minecraft_Java_Rebuild_Config() {

        #Checks if Config exists
        if [[ $JavaMinecraftConfigPath ]]; 
        then   
                #Prints Path then Creates folder path then builds config with default values
                echo "removing $JavaMinecraftConfigPath"
                rm $JavaMinecraftConfigPath
                else
                        echo "no config to remove"
                fi

        function_Minecraft_Java_Create_Config

} 

# Prints the Minecraft Java Config file to terminal
function function_Minecraft_Java_Print_Config() {

        #Runs Build Function to ensure theres a config to read
        function_Minecraft_Java_Build_Config
        
        #Loads Config Variables into memory before printing
        function_Minecraft_Java_Load_Config

        #Prints Config
        echo "Location of Minecraft Directory"
        echo "$JavaMinecraftServerLocation"
        echo " "
        echo "Local Location Minecraft Backup to be placed"
        echo "$JavaMinecraftBackupLocation"
        echo " "
        echo "Rclone Location Minecraft Backup to be placed, Leave Blank if not using"
        echo "$JavaMinecraftRemoteBackupLocation"
        echo " "
        echo "Minimum memory used in GB"
        echo "$JavaMinecraftMemoryMin"
        echo " "   
        echo "Minimum memory used in GB"
        echo "$JavaMinecraftMemoryMax"
        echo " "
        echo "Version of Server.jar"
        echo "$JavaMinecraftServerVersion"
} 

#Edits the Java Minecraft Config
function function_Minecraft_Java_Edit_Config () {

        #Builds config if not present
        function_Minecraft_Java_Build_Config

        function_Minecraft_Java_Load_Config

        function_Minecraft_Java_Backup_Config

        #Opens Nano to edit config
        nano $JavaMinecraftConfigPath

        #Prints Changed Config
        function_Minecraft_Java_Print_Config
} 

# Prints the Location of the Remote backup location
function function_Minecraft_Set_Remote_Backup() {

        function_Minecraft_Java_Load_Config

        echo "$JavaMinecraftRemoteBackupLocation"
} 

# Asks for JAR URL Installs Headless Java and installes Minecraft
function function_Minecraft_Java_Download_Server () {
        
        function_Minecraft_Java_Load_Config

        #Asks for Server JAR Url
        #echo " "
        #read -p "Enter JAR URL for Minecraft Server: " JavaMinecraftServerURL
        #echo "------------------------------------------------------"
        #Makes server directory
        mkdir -p $JavaMinecraftServerLocation
        #echo "Downloading Minecraft Jar"
        #echo "-------------------------------------------"
        cd $JavaMinecraftServerLocation
        #wget $JavaMinecraftServerURL
        echo " "
        echo "$(ColorGreen '1.15.2') "
        echo "$(ColorGreen '1.16.0') "
        echo "$(ColorGreen '1.16.2') "
        echo "$(ColorGreen '1.16.5') "
        echo "$(ColorGreen 'Enter your own Direct link') "
        echo "$(ColorBlue 'Enter your Choice:') "
                read a
                case $a in
                        1.15.2) wget $JavaMinecraftServer_1_15_2 ; JavaMinecraftServerVersion="1.15.2" ;;
                        1.16.0) wget $JavaMinecraftServer_1_16_0 ; JavaMinecraftServerVersion="1.16.0" ;;
                        1.16.2) wget $JavaMinecraftServer_1_16_2 ; JavaMinecraftServerVersion="1.16.2" ;;
                        1.16.5) wget $JavaMinecraftServer_1_16_5 ; JavaMinecraftServerVersion="1.16.5" ;;
                        *) wget $a ; read -p "Enter the Version of minecraft downloaded" JavaMinecraftServerVersion;;
                esac
        chmod u+x server.jar
        function_Minecraft_Java_Backup_Config
        function_Minecraft_Java_Rebuild_Config

} 

# Asks for JAR URL Installs Headless Java and installes Minecraft
function function_Minecraft_Java_Update_Server () {
        
        function_Minecraft_Java_Load_Config

        function_Minecraft_Java_Stop_Server

        #checking if Minecraft Server is installed by checking if server.jar is in the right place
        if [[  $JavaMinecraftServerLocation/server.jar ]]; 
                then
                        echo "Deleting Server.jar"
                        rm $JavaMinecraftServerLocation/server.jar
                fi
        function_Minecraft_Java_Download_Server

} 

# Asks for JAR URL Installs Headless Java and installes Minecraft
function function_Minecraft_Java_Install_Server () {
        
        function_Minecraft_Java_Load_Config

        # Call Java Installer
        function_install_OpenJDK

        #checking if Minecraft Server is installed by checking if server.jar is in the right place
        if [[ ! -f  $JavaMinecraftServerLocation/server.jar ]]; 
                then
                        function_Minecraft_Java_Download_Server
                else
                        echo "-------------------------------------------"
                fi
} 

function function_Minecraft_Java_Backup () {

        function_Minecraft_Java_Load_Config

        JavaMinecraftRcloneRoot="$JavaMinecraftRemoteBackupLocation:/$JavaMinecraftScreenSession-$JavaMinecraftServerVersion"
        
        #Creatng Variable that stores zip naming stratagy
        JavaMinecraftBackupZip=$JavaMinecraftBackupLocation/$startdate/backup-$JavaMinecraftScreenSession--$starttime.zip
        echo ""
        echo "---------------------------------------------------------------------------"
        echo "Starting Backup"
                mkdir -p $JavaMinecraftBackupLocation
                mkdir -p $JavaMinecraftBackupLocation/$startdate
                mkdir -p $JavaMinecraftServerLocation/bakupConfig
                mkdir -p $JavaMinecraftServerLocation/backupCrontab
                mkdir -p $JavaMinecraftServerLocation/crash-reports
                mkdir -p $JavaMinecraftServerLocation/logs
                mkdir -p $JavaMinecraftServerLocation/logs-latest
                mkdir -p $JavaMinecraftServerLocation/logs-rclone 
        echo "---------------------------------------------------------------------------"
        echo "Turn off Auto-Save + Save Game"
                screen -r $JavaMinecraftScreenSession -X stuff 'say Starting Backup\n'
                screen -r $JavaMinecraftScreenSession -X stuff 'save-off\n'
                screen -r $JavaMinecraftScreenSession -X stuff 'save-all\n'
        echo "---------------------------------------------------------------------------"
        echo "Copying Live Server Log"
                cp $JavaMinecraftServerLocation/logs/latest.log $JavaMinecraftServerLocation/logs-latest/$JavaMinecraftScreenSession-latest-$starttime.log
        echo "---------------------------------------------------------------------------"
        echo "Copying Server config"
                function_Minecraft_Java_Backup_Config
        echo "---------------------------------------------------------------------------"
        echo "Copying Server Crontab"
                crontab -l > $JavaMinecraftServerLocation/backupCrontab/crontab-$JavaMinecraftScreenSession-$starttime.config
        echo "---------------------------------------------------------------------------"
        echo "Zip Minecraft Folder"
                zip -r $JavaMinecraftBackupZip $JavaMinecraftServerLocation --exclude="*/.*"
        echo "---------------------------------------------------------------------------"
        echo "Turn on Auto-Save"
                screen -r $JavaMinecraftScreenSession -X stuff 'say Backup Complete\n'
                screen -r $JavaMinecraftScreenSession -X stuff 'save-on\n'
        echo "---------------------------------------------------------------------------"
        echo "Upload to Cloud via Rclone"
                rclone copy -P $JavaMinecraftBackupLocation $JavaMinecraftRcloneRoot/Backups --log-file=$JavaMinecraftServerLocation/logs-rclone/$JavaMinecraftScreenSession-rclone-$starttime.log
        echo "---------------------------------------------------------------------------"
        echo "Remove Backup Zips older than 7 days"
                find $JavaMinecraftBackupLocation -type f -name "*.zip" -mtime +7 -exec rm {} \;
        echo "---------------------------------------------------------------------------"
        echo "Backup Server Logs to Cloud"
                rclone copy -P $JavaMinecraftServerLocation/logs $JavaMinecraftRcloneRoot/Logs-Server
                rclone copy -P $JavaMinecraftServerLocation/logs-latest $JavaMinecraftRcloneRoot/Logs-Latest
                rclone copy -P $JavaMinecraftServerLocation/crash-reports  $JavaMinecraftRcloneRoot/Crash-Reports
        echo "---------------------------------------------------------------------------"
        echo "Removing logs older than 7 Days"
                find $JavaMinecraftServerLocation/logs -type f -name "*.gz" -mtime +7 -exec rm {} \;
                find $JavaMinecraftServerLocation/logs-latest -type f -name "*.gz" -mtime +7 -exec rm {} \;
                find $JavaMinecraftServerLocation/crash-reports -type f -name "*.gz" -mtime +7 -exec rm {} \;
        echo "---------------------------------------------------------------------------"
        ls -l $JavaMinecraftBackupLocation
        echo " "
        echo "Job Started:  $starttime"
        echo "Job Ended:    $(date +%Y%m%d-%H%M%S)"
        echo " "
} 

#//////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////

# Only to be ran in a UDM or UDM Pro!!

# Restarts UDM or UDM Pro Network Controller
function function_Unifi_Restart_UDM_Controller () {
    #Unifi - Restart UDM Network Controller
    podman restart unifi-os
} 

# Restarts UDM or UDM Pro device (Hardware)
function function_Unifi_Restart_UDM () {
    #Unifi - Halt OS
    podman stop unifi-os echo 1 > /proc/sys/kernel/sysrq echo s > /proc/sysrq-trigger echo o > /proc/sysrq-trigger
} 

# Run with Caution!!!!   Upgrades the Network Controller firmware on a UDM
function function_Unifi_Upgrade_UDM_Firmware () {
    #Unifi - Upgrade UDM Firmware
    unifi-os shell
    rm unifi_sysvinit_all.deb &> /dev/null; curl -o "/tmp/unifi_sysvinit_all.deb" https://dl.ui.com/unifi/6.0.23-20b313f50d/unifi_sysvinit_all.deb && dpkg -i /tmp/unifi_sysvinit_all.deb && rm /tmp/unifi_sysvinit_all.deb
} 

# To be ran on switches and AP's that support Switches
# Sets devices inform url to UDM IP
function function_Unifi_Set_Inform_URL () {

        #Asks for Unifi Network Controller IP
        read -p "Enter IP Address for Unifi Network Controller Ex: 10.10.1.1" UnifiInformURL
        echo "------------------------------------------------------"

        #Sets Inform URL from VAR
        set-inform http://$UnifiInformURL:8080/inform
        set-inform http://$UnifiInformURL:8080/inform
} 

#Installs Rclone on UDM or UDM Pro
function function_Unifi_Install_Rclone_Unifi () {
        unifi-os shell
        curl https://rclone.org/install.sh | sudo bash 
        rclone config
} 

#//////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////

function function_Plex_Start_Server () {
        echo "Starting Plex Server"
        echo "--------------------"
        service plexmediaserver start
} 

function function_Plex_Restart_Server () {
        echo "Restarting Plex Server"
        echo "----------------------"
        service plexmediaserver stop
        service plexmediaserver restart
} 

function function_Plex_Stop_Server () {
        echo "Starting Plex Server"
        echo "--------------------"
        service plexmediaserver stop
} 

#//////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////

function function_Install_Pi_Hole () {
    #Install - Plex Media Server
    sudo apt update
    wget -O basic-install.sh https://install.pi-hole.net
    sudo bash basic-install.sh
} 

function function_Update_Pi_Hole () {
    #Install - Plex Media Server
    sudo apt update
    wget -O basic-install.sh https://install.pi-hole.net
    sudo bash basic-install.sh
} 

#//////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////

function function_System_List_MOTD () {
    #Install - Plex Media Server
    ls -l /etc/update-motd.d/
} 

# Increases the size of the swapfile to 4Gb
function function_System_Change_Timezone () {

        echo "The Current Date and Timezone is:"
        date
        cat /etc/timezone

        echo " "
        echo "Example Timezone"
        echo "    America/New_York"
        echo "    America/Los_Angeles"
        read -p "What time zone do you want to change to: " your_time_zone

        if grep -Fxq "$your_time_zone" /usr/share/zoneinfo
                then
                        sudo timedatectl set-timezone $your_time_zone
                        echo " "
                        echo "Timezone updated to" 
                        cat /etc/timezone
                else
                        echo "Input of : $your_time_zone"
                        echo "Please choose a correct timezone"
                fi
}

# Function runs system and application updates avaliable though Apt
function function_Update_OS () {

        echo "Updating your OS"
        sudo apt-get update
        sudo apt-get upgrade -f --assume-yes
        sudo apt autoremove
}

# Increases the size of the swapfile to 4Gb
function function_Increase_Swap_File () {
        sudo swapoff /swapfile
        sudo fallocate -l 2G /swapfile
        sudo mkswap /swapfile
        sudo swapon /swapfile
}

#//////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////

menu_Bitwarden(){
echo -ne "
---------------------------------
Bitwarden Menu
---------------------------------
$(ColorGreen '1)') Update Bitwarden
$(ColorGreen '2)') Build Bitwarden Backup Config
$(ColorGreen '3)') Start Bitwarden 
$(ColorGreen '4)') Stop Bitwarden
$(ColorGreen '5)') Restart Bitwarden
$(ColorGreen '6)') Back to Main Menu
$(ColorGreen '0)') Exit
$(ColorBlue 'Choose an option:') "
        read a
        case $a in
	        1) function_Update_OS ; ./bitwarden.sh updateself ; ./bitwarden.sh update ; menu_Bitwarden ;;
	        2) function_Bitwarden_Build_Config ; menu_Bitwarden ;;
	        3) ./bitwarden.sh start ; menu_Bitwarden ;;
	        4) ./bitwarden.sh stop ; menu_Bitwarden ;;
	        5) ./bitwarden.sh restart ; menu_Bitwarden ;;
                6) ;;
		0) exit 0 ;;
		*) echo -e $red"Wrong option!!! Choose Again."$clear; menu_Bitwarden;;
        esac
}

#//////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////

menu_minecraft_bedrock(){

#check if config exists
#load config
#read config
echo -ne "
---------------------------------
minecraft
---------------------------------
$(ColorGreen '1)') Start Minecraft Server
$(ColorGreen '2)') Connect to Minecraft Server
$(ColorGreen '3)') Restart Minecraft Server
$(ColorGreen '4)') Stop Minecraft Server
$(ColorGreen '5)') Backup Minecraft Server
$(ColorGreen '6)') Print Config
$(ColorGreen '7)') Back to Main Menu
$(ColorGreen '0)') Exit
$(ColorBlue 'Choose an option:') "
        read a
        case $a in
	        1) echo "STUB" ; menu_minecraft_bedrock ;;
	        2) echo "STUB" ; menu_minecraft_bedrock ;;
	        3) echo "STUB" ; menu_minecraft_bedrock ;;
	        4) echo "STUB" ; menu_minecraft_bedrock ;;
	        5) echo "STUB" ; menu_minecraft_bedrock ;;
	        6) echo "STUB" ; menu_minecraft_bedrock ;;
                7) ;;
		0) exit 0 ;;
		*) echo -e $red"Wrong option!!! Choose Again."$clear; menu_minecraft_bedrock;;
        esac
}

#//////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////

menu_minecraft_java(){

#check if config exists
#load config
#read config
echo -ne "
---------------------------------
minecraft
---------------------------------
$(ColorGreen '1)') Start Minecraft Server
$(ColorGreen '2)') Connect to Minecraft Server
$(ColorGreen '3)') Restart Minecraft Server
$(ColorGreen '4)') Stop Minecraft Server
$(ColorGreen '5)') Backup Minecraft Server
$(ColorGreen '6)') Print Config
$(ColorGreen '7)') Edit Config
$(ColorGreen '8)') Update Minecraft Server
$(ColorGreen '9)') Install Minecraft Server
$(ColorGreen '10)') Edit EULA
$(ColorGreen '11)') Edit Properties
$(ColorGreen '12)') Back to Main Menu
$(ColorGreen '0)') Exit
$(ColorBlue 'Choose an option:') "
        read a
        case $a in
	        1) function_Minecraft_Java_Start_Server ; menu_minecraft_java ;;
	        2) function_Minecraft_Connect ; menu_minecraft_java ;;
	        3) function_Minecraft_Java_Restart_Server ; menu_minecraft_java ;;
	        4) function_Minecraft_Java_Stop_Server ; menu_minecraft_java ;;
	        5) function_Minecraft_Java_Backup ; menu_minecraft_java ;;
	        6) function_Minecraft_Java_Print_Config ; menu_minecraft_java ;;
                7) function_Minecraft_Java_Edit_Config ; menu_minecraft_java ;;
                8) function_Minecraft_Java_Update_Server ; menu_minecraft_java ;;
                9) function_Minecraft_Java_Install_Server ; menu_minecraft_java ;;
                10) function_Minecraft_Java_Edit_EULA ; menu_minecraft_java ;;
                11) function_Minecraft_Java_Edit_Properties ; menu_minecraft_java ;;
                12) ;;
		0) exit 0 ;;
		*) echo -e $red"Wrong option!!! Choose Again."$clear; menu_minecraft_java;;
        esac
}

#//////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////

menu_Netdata(){
echo -ne "
---------------------------------
Netdata Menu
---------------------------------
$(ColorGreen '1)') Update Netdata
$(ColorGreen '2)') Install Netdata
$(ColorGreen '3)') Start Netdata 
$(ColorGreen '4)') Stop Netdata
$(ColorGreen '5)') Restart Netdata
$(ColorGreen '6)') Back to Main Menu
$(ColorGreen '0)') Exit
$(ColorBlue 'Choose an option:') "
        read a
        case $a in
	        1) function_Update_OS ; menu_Netdata ;;
	        2) function_Install_Netdata ; menu_Netdata ;;
	        3) service netdata start ; menu_Netdata ;;
	        4) service netdata stop ; menu_Netdata ;;
	        5) service netdata restart ; menu_Netdata ;;
                6) ;;
		0) exit 0 ;;
		*) echo -e $red"Wrong option!!! Choose Again."$clear; menu_Netdata;;
        esac
}

#//////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////

menu_PiHole(){
pihole version
pihole status
echo -ne "
---------------------------------
piHole
Version: "pihole version"
Status: "pihole status"
---------------------------------
$(ColorGreen '1)') Update PiHole
$(ColorGreen '2)') Install PiHole
$(ColorGreen '3)') Restart DNS Server
$(ColorGreen '4)') Backup Pi-Hole Here
$(ColorGreen '5)') Back to Main Menu
$(ColorGreen '0)') Exit
$(ColorBlue 'Choose an option:') "
        read a
        case $a in
	        1) pihole -up ; menu_PiHole ;;
	        2) function_Install_Pi_Hole ; menu_PiHole ;;
	        3) pihole restartdns ; menu_PiHole ;;
	        4) pihole -a -t ; menu_PiHole ;;
                5) ;;
		0) exit 0 ;;
		*) echo -e $red"Wrong option!!! Choose Again."$clear; menu_PiHole;;
        esac
}

#//////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////

menu_plex(){
echo -ne "
---------------------------------
PLEX Menu
---------------------------------
$(ColorGreen '1)') Update Plex
$(ColorGreen '2)') Install Server
$(ColorGreen '3)') Restart Server
$(ColorGreen '4)') Start Server
$(ColorGreen '5)') Stop Server
$(ColorGreen '6)') Back to Main Menu
$(ColorGreen '0)') Exit
$(ColorBlue 'Choose an option:') "
        read a
        case $a in
            1) function_Update_OS ; menu_plex ;;
            2) function_Install_PlexMediaServer ; menu_plex ;;
            3) function_Plex_Restart_Server ; menu_plex ;;
            4) function_Plex_Start_Server ; menu_plex ;;
            5) function_Plex_Stop_Server ; menu_plex ;;
            6) ;;
            0) exit 0 ;;
            *) echo -e $red"Wrong option!!! Choose Again."$clear; menu_plex;;
        esac
}

#//////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////

menu_System(){
echo -ne "
---------------------------------
System Menu
---------------------------------
$(ColorGreen '1)') Show MOTD Files
$(ColorGreen '2)') Install Custom MOTD
$(ColorGreen '3)') Uninstall OpenJDK 8 Headless
$(ColorGreen '4)') Change Swap File Size to 2GB
$(ColorGreen '5)') Change Timezone
$(ColorGreen '6)') Install rclone
$(ColorGreen '7)') Install Tailscale
$(ColorGreen '8)') NA
$(ColorGreen '0)') Exit
$(ColorBlue 'Choose an option:') "
        read a
        case $a in
	        1) function_System_List_MOTD ; menu_System ;;
	        2) wget $MotdURL -P /etc/update-motd.d ; menu_System ;;
	        3) function_OpenJDK_8_Headless_Uninstall ; menu_System ;;
	        4) function_Increase_Swap_File ; menu_System ;;
	        5) function_System_Change_Timezone ; menu_System ;;
                6) curl https://rclone.org/install.sh | sudo bash ; menu_System ;;
                7) function_Tailscale_Install ; menu_System ;;
                7) ;;
		0) exit 0 ;;
		*) echo -e $red"Wrong option!!! Choose Again."$clear; menu_System;;
        esac
}

#//////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////

menu_unifi(){
echo -ne "
---------------------------------
UNIFI Menu
---------------------------------
$(ColorGreen '1)') Update Unifi
$(ColorGreen '2)') Restart UDM
$(ColorGreen '3)') Restart UDM Network Controller
$(ColorGreen '4)') Upgrade UDM Firmware
$(ColorGreen '5)') Set Inform URL (Switches/APs Only)
$(ColorGreen '6)') Back to Main Menu
$(ColorGreen '0)') Exit
$(ColorBlue 'Choose an option:') "
        read a
        case $a in
	        1) function_Update_OS ; menu_unifi ;;
	        2) function_Unifi_Restart_UDM ; menu_unifi ;;
	        3) function_Unifi_Restart_UDM_Controller ; menu_unifi ;;
	        4) function_Unifi_Upgrade_UDM_Firmware ; menu_unifi ;;
	        5) function_Unifi_Set_Inform_URL ; menu_unifi ;;
                6) ;;
		0) exit 0 ;;
		*) echo -e $red"Wrong option!!! Choose Again."$clear; menu_unifi;;
        esac
}

#//////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////

menu_Installers(){
echo -ne "
---------------------------------
Script Menu
---------------------------------
$(ColorGreen '1)') Install Fail2ban
$(ColorGreen '2)') Install Java
$(ColorGreen '3)') Install 
$(ColorGreen '0)') Exit
$(ColorBlue 'Choose an option:') "
        read a
        case $a in
	        1) function_Install_Fail2Ban ; menu_Installers ;;
	        2) function_install_OpenJDK ; menu_Installers ;;
	        3) ;;
		0) exit 0 ;;
		*) echo -e $red"Wrong option!!! Choose Again."$clear; menu_Installers;;
        esac
}

#//////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////

menu_main(){
echo -ne "
$(ColorGreen ' 1)') Update OS
$(ColorGreen ' 2)') System Utilities
$(ColorGreen ' 3)') Installers
$(ColorGreen ' 4)') Bitwarden 
$(ColorGreen ' 5)') Minecraft Bedrock Edition
$(ColorGreen ' 6)') Minecraft Java Edition
$(ColorGreen ' 7)') Netdata
$(ColorGreen ' 8)') PiHole
$(ColorGreen ' 9)') Plex
$(ColorGreen '10)') Plex
$(ColorGreen ' 0)') Exit
$(ColorBlue 'Choose an option:') "
        read a
        case $a in
	        1) function_Update_OS ; menu_main ;;
	        2) menu_System ; menu_main ;;
	        3) menu_Installers ; menu_main ;;
	        4) menu_Bitwarden ; menu_main ;;
	        5) menu_minecraft_bedrock ; menu_main ;;
	        6) menu_minecraft_java ; menu_main ;;
	        7) menu_Netdata ; menu_main ;;
	        8) menu_PiHole ; menu_main ;;
                9) menu_plex ; menu_main ;;
               10) menu_unifi ; menu_main ;;
		0) exit 0 ;;
		*) echo -e $red"Wrong option!!! Choose Again."$clear; menu_main;;
        esac
}

#//////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////

if [[ "$1" == "update" ]];
        then
                function_Update_OS
#--------------------------------------------------
elif [[ "$1" == "restart" ]];
        then
                sudo restart
#--------------------------------------------------
elif [[ "$1" == "mcbackup" ]];
        then
                function_Minecraft_Java_Backup
#--------------------------------------------------
elif [[ "$1" == "javamcstart" ]];
        then
                function_Minecraft_Java_Start_Server
#--------------------------------------------------
elif [[ "$1" == "minecraft" ]];
        then
                menu_minecraft_java
#--------------------------------------------------
elif [[ "$1" == "swapincrease" ]];
        then
                function_Increase_Swap_File
#--------------------------------------------------
        else
                # Call the menu function
                menu_main
fi
exit 0
