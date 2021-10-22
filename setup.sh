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
    sqlite3 "$baseFolder/dataAndScripts/seq2mgs.db" \
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

pathMessage="\nPlease make sure to install the missing dependency if not done so\n"\
" AND make sure it is in the "'$PATH'" variable:\n"\
'  export PATH=/path/to/program/folder/:$PATH'

# STEP 1 - Check dependencies
#----------------------------
echo "1) Check dependencies..."

#Check if sqlite3 is installed
testTool=`command -v sqlite3`
if [ -z "$testTool" ]; then 
	echo -e "\e[91msqlite3 was not found\e[0m"
	echo -e $pathMessage
	exit 1;
fi;
echo -e " - SQLite 3 is present"

#Check the seq2mgs database and create if needed
if [ ! -f "$baseFolder/dataAndScripts/seq2mgs.db" ]; then
	sqlite3 "$baseFolder/dataAndScripts/seq2mgs.db" -cmd \
	".read $baseFolder/dataAndScripts/createSeq2mgsDB.sql" ".quit" 
	echo -e " - No seq2mgs database found, a new database was created"
else 
	echo -e " - The seq2mgs database is present"
fi

#Register the start of the script in the DB
runId=$(sqlite3 "$baseFolder/dataAndScripts/seq2mgs.db" \
	"INSERT INTO scriptUse (scriptName,start,status) \
	values('setup.sh','$(date '+%F %T')','running'); \
	SELECT runId FROM scriptUse WHERE runId = last_insert_rowid()")
	
#Check if bbmap is installed or the reformat.sh script can be reached
if [ -z `command -v reformat.sh` ]; then 
	echo -e "\e[91mThe bbmap package was not found\e[0m"
	echo -e $pathMessage
	updateDBwhenError "$runId" "The bbmap package was not found"
	exit 1;
elif [ -z `command -v java` ]; then 
    echo -e "\e[91mThe bbmap package is installed, but the java dependency was not found\n"\
	"Make sure to install java (version 7+) on your system\e[0m"
	echo -e $pathMessage
	updateDBwhenError "$runId" "The java dependency was not found"
	exit 1;
fi;
sqlite3 "$baseFolder/dataAndScripts/seq2mgs.db" \
	"INSERT INTO logs (runId,tool,timeStamp,actionId,actionName)
	VALUES($runId,'setup.sh',$(date '+%s'),3,'bbmap (reformat.sh) installed')"
echo -e " - bbmap is present"

#Check if pigz is installed else use gzip (slower but same result)
if [ -z `command -v pigz` ]; then 
	message="pigz not found. gzip used instead (slower)"
else
	message="pigz is present"
fi;
sqlite3 "$baseFolder/dataAndScripts/seq2mgs.db" \
	"INSERT INTO logs (runId,tool,timeStamp,actionId,actionName)
	VALUES($runId,'setup.sh',$(date '+%s'),7,'$message')"
echo -e " - $message"

#Check if SRAtoolkit (fasterq-dump) is installed
if [ -z `command -v fasterq-dump` ]; then 
	message="SRAtoolkit was NOT found. Only local data can be used as input"
else
	message="SRAtoolkit is present"
fi;
sqlite3 "$baseFolder/dataAndScripts/seq2mgs.db" \
	"INSERT INTO logs (runId,tool,timeStamp,actionId,actionName)
	VALUES($runId,'setup.sh',$(date '+%s'),7,'$message')"
echo -e " - $message"

#Check if R is installed
if [ -z `command -v Rscript` ]; then 
    echo -e "\e[91mRscript is not found\e[0m"
	echo -e $pathMessage
	updateDBwhenError "$runId" "R is not found"
	exit 1;
fi;
sqlite3 "$baseFolder/dataAndScripts/seq2mgs.db" \
	"INSERT INTO logs (runId,tool,timeStamp,actionId,actionName)
	VALUES($runId,'setup.sh',$(date '+%s'),1,'R installed')"

#Check if the correct R packages are installed
Rscript $baseFolder/dataAndScripts/setup.R
sqlite3 "$baseFolder/dataAndScripts/seq2mgs.db" \
	"INSERT INTO logs (runId,tool,timeStamp,actionId,actionName)
	VALUES($runId,'setup.R',$(date '+%s'),2,'R packages installed')"
echo -e " - R and dependent packages are present"

echo -e "   ... finished\n"
finalMessage=" All dependencies seem to be present\n"


if [ "$runTests" == "true" ]; then
	#STEP 2 - Test metaMixing
	#------------------------
	printf "2) Test mixing metagenome... "

	#Create input file
	cat $baseFolder/dataAndScripts/testData/input.csv | awk '{gsub(/~/,"'$baseFolder'")}1' > \
		$baseFolder/dataAndScripts/testData/testInput.csv

	#Run seq2mgs.sh
	$baseFolder/seq2mgs.sh -f \
		-i $baseFolder/dataAndScripts/testData/testInput.csv \
		-o $baseFolder/dataAndScripts/testData/testOutput.fastq.gz \
		-v FALSE

	sqlite3 "$baseFolder/dataAndScripts/seq2mgs.db" \
		"INSERT INTO logs (runId,tool,timeStamp,actionId,actionName)
		VALUES($runId,'setup.sh',$(date '+%s'),8,'seq2mgs test succesful')"
	printf "done\n\n"
	
	finalMessage="$finalMessage  Mixing test successful\n"
fi

#Finish script
sqlite3 "$baseFolder/dataAndScripts/seq2mgs.db" \
	"UPDATE scriptUse
	SET end = '$(date '+%F %T')', status = 'finished'
	WHERE runId = $runId"
	
echo -e `date "+%T"`" - Setup check finished succesfully\n \e[32m$finalMessage\e[0m"
