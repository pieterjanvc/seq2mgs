#!/bin/bash

baseFolder=$(realpath -- "$(dirname -- "$0")")

#Save error to temp file to it can be both displayed to user and put in DB
touch $baseFolder/dataAndScripts/lastError
exec 2>$baseFolder/dataAndScripts/lastError

#When error occurs, notify and exit
err_report() {

    #Use the line number where error occured and the saved error message
    errMsg=`cat $baseFolder/dataAndScripts/lastError` 
	
	#Insert into DB (make sure quoting is all right)
	errMsg=$(sed 's/'\''/&&/g' <<< "$errMsg")
    updateDBwhenError "$runId" "ERROR LINE $1: $errMsg"
	
	#Report error to stdout too 
	echo -e "\n\e[91m--- ERROR LINE $1 ---\n"
	echo -n "$errMsg"
	echo -e "\e[0m"
	
	exit 1;
}
trap 'err_report ${LINENO}' ERR

updateDBwhenError() {
	#Update the DB
    $sqlite3 "$baseFolder/dataAndScripts/metaMixer.db" \
	"UPDATE scriptUse
	SET end = '$(date '+%F %T')', status = 'error',
	info = '$2'
	WHERE runId = $1"
}

while getopts ":ht" opt; do
  case $opt in
	h) echo -e "\n"
	   awk '/--- SETUP.SH ---/,/-- END SETUP.SH ---/' $baseFolder/readme.txt
	   echo -e "\n"
	   exit
    ;;
	t) runTests=true
	;;
    \?) echo "Unknown argument provided"
	    exit
	;;
  esac  
done

echo -e `date "+%T"`"\e[32m - Start the setup check...\e[0m\n"

#Create folders if needed
mkdir -p $baseFolder/SRAdownloads
mkdir -p $baseFolder/SRAdownloads/temp
mkdir -p $baseFolder/temp

# STEP 1 - Check dependencies
#----------------------------
echo "1) Check dependencies..."

#Check if sqlite3 is installed
sqlite3=`grep -oP "sqlite3\s*=\s*\K(.*)" $baseFolder/settings.txt`
testTool=`command -v $sqlite3`
if [ -z "$testTool" ]; then 
    message="SQLite 3 does not seem to be installed.\n If it is, set the path to 'sqlite3' in the settings file"
	echo -e "\e[91m$message\n" $baseFolder/settings.txt"\e[0m"
	exit 1;
fi;
echo -e " - SQLite 3 is present"

#Check the metaMixer database and create if needed
if [ ! -f "$baseFolder/dataAndScripts/metaMixer.db" ]; then
	$sqlite3 "$baseFolder/dataAndScripts/metaMixer.db" -cmd \
	".read $baseFolder/dataAndScripts/createMetaMixerDB.sql" ".quit" 
	echo -e " - No metaMixer database found, a new database was created"
else 
	echo -e " - The metaMixer database is present"
fi

#Register the start of the script in the DB
runId=$($sqlite3 "$baseFolder/dataAndScripts/metaMixer.db" \
	"INSERT INTO scriptUse (scriptName,start,status) \
	values('setup.sh','$(date '+%F %T')','running'); \
	SELECT runId FROM scriptUse WHERE runId = last_insert_rowid()")
	
#Check if R is installed
Rscript=`grep -oP "rscript\s*=\s*\K(.*)" $baseFolder/settings.txt`
if [ -z `command -v $Rscript` ]; then 
    message="R does not seem to be installed.\n If it is, set the path to 'Rscript' in the settings file"
	echo -e "\e[91m$message\n" $baseFolder/settings.txt"\e[0m"
	updateDBwhenError "$runId" "R does not seem to be installed"
	exit 1;
fi;
$sqlite3 "$baseFolder/dataAndScripts/metaMixer.db" \
	"INSERT INTO logs (runId,tool,timeStamp,actionId,actionName)
	VALUES($runId,'setup.sh',$(date '+%s'),1,'R installed')"

#Check if the correct R packages are installed
$Rscript $baseFolder/dataAndScripts/setup.R
$sqlite3 "$baseFolder/dataAndScripts/metaMixer.db" \
	"INSERT INTO logs (runId,tool,timeStamp,actionId,actionName)
	VALUES($runId,'setup.R',$(date '+%s'),2,'R packages installed')"
echo -e " - R and dependent packages are present"


#Check if bbmap is installed or the reformat.sh script can be reached
testTool=`grep -oP "reformat\s*=\s*\K(.*)" $baseFolder/settings.txt`
if [ -z `command -v $testTool` ]; then 
	echo -e "\e[91mThe bbmap package does not seem to be installed as a system application\n"\
	"If you have unzipped the package in a custom folder,\n update the path to the 'reformat.sh' script in the settings file\n"\
	$baseFolder/settings.txt"\e[0m"
	updateDBwhenError "$runId" "The bbmap package does not seem to be installed"
	exit 1;
fi;
$sqlite3 "$baseFolder/dataAndScripts/metaMixer.db" \
	"INSERT INTO logs (runId,tool,timeStamp,actionId,actionName)
	VALUES($runId,'setup.sh',$(date '+%s'),3,'bbmap (reformat.sh) installed')"
echo -e " - bbmap (reformat.sh) is present"

#Check if pigz is installed else use gzip (slower but same result)
if [ -z `command -v pigz` ]; then 
	echo -e " - pigz is not present. gzip will be used instead, but is slower"
	message="pigz not installed. gzip used instead"
else
	message="pigz present"
fi;
$sqlite3 "$baseFolder/dataAndScripts/metaMixer.db" \
	"INSERT INTO logs (runId,tool,timeStamp,actionId,actionName)
	VALUES($runId,'setup.sh',$(date '+%s'),7,'$message')"
echo -e " - $message"

#Check if SRAtoolkit (fasterq-dump) is installed
testTool=`grep -oP "fasterq\s*=\s*\K(.*)" $baseFolder/settings.txt`
if [ -z `command -v $testTool` ]; then 
	echo -e " - SRAtoolkit (fasterq-dump) is not present. Only local data can be used as input"
	message="SRAtoolkit (fasterq-dump) not installed"
else
	message="SRAtoolkit (fasterq-dump) present"
fi;
$sqlite3 "$baseFolder/dataAndScripts/metaMixer.db" \
	"INSERT INTO logs (runId,tool,timeStamp,actionId,actionName)
	VALUES($runId,'setup.sh',$(date '+%s'),7,'$message')"
echo -e " - $message"

echo -e "   ... finished\n"
finalMessage=" All dependencies seem to be present\n"


if [ "$runTests" == "true" ]; then
	#STEP 2 - Test metaMixing
	#------------------------
	printf "2) Test mixing metagenome... "

	#Create input file
	cat $baseFolder/dataAndScripts/testData/input.csv | awk '{gsub(/~/,"'$baseFolder'")}1' > \
		$baseFolder/dataAndScripts/testData/testInput.csv

	#Run metaMixer.sh
	$baseFolder/metaMixer.sh -f \
		-i $baseFolder/dataAndScripts/testData/testInput.csv \
		-o $baseFolder/dataAndScripts/testData/testOutput.fastq.gz \
		-v FALSE

	$sqlite3 "$baseFolder/dataAndScripts/metaMixer.db" \
		"INSERT INTO logs (runId,tool,timeStamp,actionId,actionName)
		VALUES($runId,'setup.sh',$(date '+%s'),8,'metaMixer test succesful')"
	printf "done\n\n"
	
	finalMessage="$finalMessage  Mixing test successful\n"
fi

#Finish script
$sqlite3 "$baseFolder/dataAndScripts/metaMixer.db" \
	"UPDATE scriptUse
	SET end = '$(date '+%F %T')', status = 'finished'
	WHERE runId = $runId"
	
echo -e `date "+%T"`" - Setup check finished succesfully\n \e[32m$finalMessage\e[0m"
