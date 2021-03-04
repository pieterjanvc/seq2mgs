#!/bin/bash

baseFolder=$(realpath -- "$(dirname -- "$0")")
sqlite3=`grep -oP "sqlite3\s*=\s*\K(.*)" $baseFolder/settings.txt`

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

#Options when script is run
while getopts ":hi:o:t:l:u::m:fv:" opt; do
  case $opt in
	h) echo -e "\n"
	   awk '/--- metaMixer.SH ---/,/-- END metaMixer.SH ---/' $baseFolder/readme.txt 
	   echo -e "\n"
	   exit
    ;;	
	i) inputFile=`realpath "${OPTARG}"`
    ;;
	o) outputFile=`realpath "${OPTARG}"`
    ;;
	t) tempFolder=`realpath "${OPTARG}"`
    ;;
	l) lowerLimit="${OPTARG}"
    ;;
	u) upperLimit="${OPTARG}"
    ;;
	m) metaData="${OPTARG}"
    ;;
	f) forceOverwrite=T
    ;;
	v) verbose="${OPTARG}"
    ;;
    \?) echo "Unknown argument provided"
	    exit
	;;
  esac  
done

exec 2>$baseFolder/dataAndScripts/lastError

#Check all the input arguments
if [ -z ${inputFile+x} ]; then 
	echo -e "\n\e[91mNo input file found, type metaMixer -h for more info\e[0m"; exit 1; 
elif [ ! -f $inputFile ]; then 
	echo -e "\n\e[91mThe specified input file was not found\e[0m"; exit 1; 
fi

if [ -z ${outputFile+x} ]; then 
	echo -e "\n\e[91mNo output file specified.\n Use -o to specifiy one or type metaMixer -h for more info\e[0m"; exit 1;
elif [ ! -d `dirname $outputFile` ]; then	
	echo -e "\n\e[91mThe directory for the output file does not exist\e[0m"; exit 1;
elif [ -f $outputFile ] && [ -z ${forceOverwrite+x} ]; then	
	echo -e "\n\e[91mThe output file already exists.\n Use -f option to force overwrite\e[0m"; exit 1;
fi

if [ -z ${lowerLimit+x} ]; then 
	lowerLimit=0
elif [[ ! $lowerLimit =~ ^[0-9]+$ ]]; then 
	echo -e "\n\e[91mThe read limit must be a positive integer\e[0m"; exit 1; 
fi

if [ -z ${upperLimit+x} ]; then 
	upperLimit=0
elif [[ ! $upperLimit =~ ^[0-9]+$ ]]; then 
	echo -e "\n\e[91mThe read limit must be a positive integer\e[0m"; exit 1; 
fi

if [ -z ${tempFolder+x} ]; then 
	tempFolder=`grep -oP "metaMixerTemp\s*=\s*\K(.*)" $baseFolder/settings.txt`
	tempFolder=${tempFolder%/}
	if [ -z ${tempFolder} ]; then
		tempFolder=$baseFolder/temp #Use default temp if none assigned
	elif [ ! -d `dirname $tempFolder` ]; then	
		echo -e "\n\e[91mThe default temp directory set in the settings file does not exist\e[0m"; exit 1;
	fi
elif [ ! -d `dirname $tempFolder` ]; then	
	echo -e "\n\e[91mThe temp directory does not exist\e[0m"; exit 1;
fi

if [ -z ${metaData+x} ]; then 
	metaData=`grep -oP "metaMixerMetaData\s*=\s*\K(.*)" $baseFolder/settings.txt`
elif ! grep -qE "^(true|T|TRUE|false|F|FALSE)$" <<< $metaData; then	
	echo -e "\n\e[91mThe metaData option (-m) needs to be either TRUE or FALSE\e[0m"; exit 1; 
fi

if [ -z ${verbose+x} ]; then 
	verbose=`grep -oP "metaMixerVerbose\s*=\s*\K(.*)" $baseFolder/settings.txt`
elif ! grep -qE "^(true|T|TRUE|false|F|FALSE)$" <<< $verbose; then	
	echo -e "\n\e[91mThe verbose option (-v) needs to be either TRUE or FALSE\e[0m"; exit 1;
else
	verbose=`if grep -qE "^(true|T|TRUE)$" <<< $verbose; then echo T; else echo F; fi`
fi

#Register the start of the script in the DB
runId=$($sqlite3 "$baseFolder/dataAndScripts/metaMixer.db" \
	"INSERT INTO scriptUse (scriptName,start,status) \
	values('metaMixer.sh','$(date '+%F %T')','running'); \
	SELECT runId FROM scriptUse WHERE runId = last_insert_rowid()")
	
#Save the arguments with which the script was run
$sqlite3 "$baseFolder/dataAndScripts/metaMixer.db" \
	"INSERT INTO scriptArguments (runId,scriptName,argument,value)
	VALUES($runId,'metaMixer.sh','inputFile', '$inputFile'),
	($runId,'metaMixer.sh','outputFile', '$outputFile'),
	($runId,'metaMixer.sh','tempFolder', '$tempFolder'),
	($runId,'metaMixer.sh','upperLimit', '$upperLimit'),
	($runId,'metaMixer.sh','lowerLimit', '$lowerLimit'),
	($runId,'metaMixer.sh','metaData', '$metaData'),
	($runId,'metaMixer.sh','forceOverwrite', '$forceOverwrite'),
	($runId,'metaMixer.sh','verbose', '$verbose')"	

if [ $verbose == T ]; then
	echo -e "\n\e[32m"`date "+%T"`" - Start mixing reads into" `basename $outputFile` "...\e[0m"
fi

#Run the R script
rPath=`grep -oP "rscript\s*=\s*\K(.*)" $baseFolder/settings.txt`
$rPath $baseFolder/dataAndScripts/metaMixer.R \
	$baseFolder $inputFile $outputFile $lowerLimit \
	$upperLimit $metaData $verbose $tempFolder $runId

if [ $verbose == T ]; then
	echo -e "\e[32m"`date "+%T"`" - Finished mixing reads\n\e[0m"
fi

#Update the DB
$sqlite3 "$baseFolder/dataAndScripts/metaMixer.db" \
	"UPDATE scriptUse
	SET end = '$(date '+%F %T')', status = 'finished'
	WHERE runId = $runId"
