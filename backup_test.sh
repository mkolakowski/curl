#Backup Variables
    BitwardenConfigPath="/media/bitwarden-backup/bitwarden.config"
    BitwardenServerLocation="./bwdata"
    BitwardenLocalBackupLocation="/media/bitwarden-backup/Full/"
    BitwardenRemoteBackupLocation="na"

# Copies values from configuration into script
function function_Backup_Load_Config () {

        #tells the program to refrence this file
        . $BitwardenConfigPath
        #Copies variables from file (on right side) to script variables
        BitwardenLocalBackupLocation=$confBitwardenBackupLocal
        BitwardenRemoteBackupLocation=$confBitwardenRemoteBackupLocation
        BitwardenServerLocation=$confBitwardenServerLocation
} 

#Creates Config file for the Java edition of Minecraft
function function_Backup_Create_Config () {

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
function function_Backup_Build_Config() {

        function_Backup_Load_Config
        #Checks if Config exists
        if [[ ! -f $BitwardenConfigPath ]]; 
        then   
                echo "Building Config"
                #Prints Path then Creates folder path then builds config with default values
                #echo $BitwardenConfigPath
                sudo mkdir -p $BitwardenLocalBackupLocation
                function_Backup_Create_Config
                else
                        echo ""
                fi
} 

# Will exit function if config exists, WILL overwrite file USE WITH CAUTION
function function_Backup_Rebuild_Config() {

        #Checks if Config exists
        if [[ $BitwardenConfigPath ]]; 
        then   
                #Prints Path then Creates folder path then builds config with default values
                echo "removing $BitwardenConfigPath"
                rm $BitwardenConfigPath
                else
                        echo "no config to remove"
                fi

        function_Backup_Create_Config

} 

function function_Bitwarden_Backup () {

        function_Backup_Load_Config

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
