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

#Options when script is run
while getopts ":hi:o:t:l:u:a:b:d:m:fv:" opt; do
  case $opt in
	h) echo -e "\n"
	   awk '/--- SEQ2MGS.SH ---/,/-- END SEQ2MGS.SH ---/' $baseFolder/readme.txt 
	   echo -e "\n"
	   exit
    ;;	
	i) inputFile=`realpath "${OPTARG}"`
    ;;
	o) outputFile=`realpath "${OPTARG}"`
    ;;
	t) tempFolder=`realpath "${OPTARG}"`
    ;;
	l) minBases="${OPTARG}"
    ;;
	u) maxBases="${OPTARG}"
    ;;
	a) minBackBases="${OPTARG}"
    ;;
	b) maxBackBases="${OPTARG}"
    ;;
	d) defaultGenomeSize="${OPTARG}"
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

if [ $OPTIND -eq 1 ]; then 
	echo -e "\n"
	awk '/--- SEQ2MGS.SH ---/,/-- END SEQ2MGS.SH ---/' $baseFolder/readme.txt
	echo -e "\n"
	exit
fi

exec 2>$baseFolder/dataAndScripts/lastError

#Quick check whether the tool is setup correctly
if [ -z `command -v reformat.sh` ] || [ -z `command -v sqlite3` ] ||\
   [ -z `command -v Rscript` ] || [ ! -f "$baseFolder/dataAndScripts/seq2mgs.db" ]; then
	echo -e "\e[91m\nThere are issues with the setup of the tool\n please run the setup.sh script for details\e[0m"
fi

#Check all the input arguments
if [ -z ${inputFile+x} ]; then 
	echo -e "\n\e[91mNo input file found, type seq2mgs -h for more info\e[0m"; exit 1; 
elif [ ! -f $inputFile ]; then 
	echo -e "\n\e[91mThe specified input file was not found\e[0m"; exit 1; 
fi

if [ -z ${forceOverwrite+x} ]; then	
  forceOverwrite=F
fi

if [ -z ${outputFile+x} ]; then 
	echo -e "\n\e[91mNo output file specified.\n Use -o to specify one or type seq2mgs -h for more info\e[0m"; exit 1;
elif [ ! -d `dirname $outputFile` ]; then	
	echo -e "\n\e[91mThe directory for the output file does not exist\e[0m"; exit 1;
elif [ -f $outputFile ] && [ $forceOverwrite == F ]; then	
	echo -e "\n\e[91mThe output file already exists.\n Use -f option to force overwrite\e[0m"; exit 1;
elif [ -f $outputFile ] && [ $forceOverwrite == T ]; then	
  rm $outputFile
  rm -f $(echo $outputFile | sed -e "s/.fastq.gz/_metaData.json/g")
fi

if [ ! -z ${minBases+x} ] && [[ ! "$minBases" =~ ^[0-9\.+-eE]+$ ]]; then 
	echo -e "\n\e[91mThe base limit must be a positive integer\e[0m"; exit 1; 
fi

if [ ! -z ${maxBases+x} ] && [[ ! "$maxBases" =~ ^[0-9\.+-eE]+$ ]]; then 
	echo -e "\n\e[91mThe base limit must be a positive integer\e[0m"; exit 1; 
fi

if [ ! -z ${minBackBases+x} ] && [[ ! "$minBackBases" =~ ^[0-9\.+-eE]+$ ]]; then 
	echo -e "\n\e[91mThe min base limit must be a positive integer\e[0m"; exit 1; 
fi

if [ ! -z ${maxBackBases+x} ] && [[ ! "$maxBackBases" =~ ^[0-9\.+-eE]+$ ]]; then 
	echo -e "\n\e[91mThe max base limit must be a positive integer\e[0m"; exit 1; 
fi

if [ -z ${defaultGenomeSize+x} ]; then 
	defaultGenomeSize=`grep -oP "seq2mgsDefaultGenomeSize\s*=\s*\K(.*)" $baseFolder/settings.txt`
elif [[ ! "$defaultGenomeSize" =~ ^[0-9\.+-eE]+$ ]]; then 
	echo -e "\n\e[91mThe defaultGenomeSize must be a positive integer\e[0m"; exit 1; 
fi

if [ -z ${tempFolder+x} ]; then 
	tempFolder=`grep -oP "seq2mgsTemp\s*=\s*\K(.*)" $baseFolder/settings.txt`
	tempFolder=${tempFolder%/}
    if [ ! -d `dirname $tempFolder` ]; then	
		echo -e "\n\e[91mThe default temp directory set in the settings file does not exist\e[0m"; exit 1;
	fi
elif [ ! -d `dirname $tempFolder` ]; then	
	echo -e "\n\e[91mThe temp directory does not exist\e[0m"; exit 1;
fi

if [ -z ${metaData+x} ]; then 
	metaData=`grep -oP "seq2mgsMetaData\s*=\s*\K(.*)" $baseFolder/settings.txt`
elif ! grep -qE "^(true|T|TRUE|false|F|FALSE)$" <<< $metaData; then	
	echo -e "\n\e[91mThe metaData option (-m) needs to be either TRUE or FALSE\e[0m"; exit 1; 
fi

if [ -z ${verbose+x} ]; then 
	verbose=`grep -oP "seq2mgsVerbose\s*=\s*\K(.*)" $baseFolder/settings.txt`
elif ! grep -qE "^(true|T|TRUE|false|F|FALSE)$" <<< $verbose; then	
	echo -e "\n\e[91mThe verbose option (-v) needs to be either TRUE or FALSE\e[0m"; exit 1;
else
	verbose=`if grep -qE "^(true|T|TRUE)$" <<< $verbose; then echo T; else echo F; fi`
fi

#Register the start of the script in the DB
runId=$(sqlite3 "$baseFolder/dataAndScripts/seq2mgs.db" \
	"INSERT INTO scriptUse (scriptName,start,status) \
	values('seq2mgs.sh','$(date '+%F %T')','running'); \
	SELECT runId FROM scriptUse WHERE runId = last_insert_rowid()")
	
#Save the arguments with which the script was run
sqlite3 "$baseFolder/dataAndScripts/seq2mgs.db" \
	"INSERT INTO scriptArguments (runId,scriptName,argument,value)
	VALUES($runId,'seq2mgs.sh','inputFile', '$inputFile'),
	($runId,'seq2mgs.sh','outputFile', '$outputFile'),
	($runId,'seq2mgs.sh','tempFolder', '$tempFolder'),
	($runId,'seq2mgs.sh','maxBases', '$maxBases'),
	($runId,'seq2mgs.sh','minBases', '$minBases'),
	($runId,'seq2mgs.sh','maxBackBases', '$maxBackBases'),
	($runId,'seq2mgs.sh','minBackBases', '$minBackBases'),
	($runId,'seq2mgs.sh','metaData', '$metaData'),
	($runId,'seq2mgs.sh','forceOverwrite', '$forceOverwrite'),
	($runId,'seq2mgs.sh','verbose', '$verbose')"	

if [ $verbose == T ]; then
	echo -e "\n\e[32m"`date "+%T"`" - Start mixing reads into" `basename $outputFile` "...\e[0m"
fi

#Run the R script
Rscript $baseFolder/dataAndScripts/seq2mgs.R \
	$baseFolder $inputFile $outputFile "$minBases" \
	"$maxBases" $metaData $verbose $tempFolder $runId \
	"$minBackBases" "$maxBackBases" "$defaultGenomeSize"

if [ $verbose == T ]; then
	echo -e "\e[32m"`date "+%T"`" - Finished mixing reads\n\e[0m"
fi

#Update the DB
sqlite3 "$baseFolder/dataAndScripts/seq2mgs.db" \
	"UPDATE scriptUse
	SET end = '$(date '+%F %T')', status = 'finished'
	WHERE runId = $runId"
