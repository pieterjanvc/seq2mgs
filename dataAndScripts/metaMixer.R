#!/usr/bin/env Rscript
args = commandArgs(trailingOnly=TRUE)

#Load packages
suppressPackageStartupMessages(library(tidyverse))
suppressPackageStartupMessages(library(jsonlite))
suppressPackageStartupMessages(library(RSQLite))

options(digits = 10)
sTime = Sys.time()

# ---- Setup variables and directories ----
#******************************************

#Function to ensure that paths always/never end with '/'
formatPath = function(path, endWithSlash = F){
  
  if(str_detect(path, "\\/$") & endWithSlash){
    return(path)
  } else if(endWithSlash == F){
    return(str_remove(path, "\\/$"))
  } else {
    return(paste0(path, "/"))
  }
  
}

#Variables from metaMixer.sh script
baseFolder = formatPath(as.character(args[[1]]))
inputFile = as.character(args[[2]])
outputFile = as.character(args[[3]])
readLimit = as.integer(args[[4]])
metaData = as.logical(args[[5]])
verbose = as.logical(args[[6]])
tempFolder = formatPath(as.character(args[[7]]))
runId = as.integer(args[[8]])

#Grab the location of the reformat script from the settings file
reformatScript = system(sprintf("grep -oP \"reformat\\s*=\\s*\\K([^\\s]+)\" %s/settings.txt", 
                                baseFolder), intern = T)

#Grab the location of the sraDownloadFolder from the settings file
sraDownloadFolder = suppressWarnings(
  system(sprintf("grep -oP \"sraDownloadFolder\\s*=\\s*\\K([^\\s]+)\" %s/settings.txt",
                 baseFolder), intern = T))
sraDownloadFolder = ifelse(length(sraDownloadFolder) == 0, 
                           sprintf("%s/SRAdownloads", baseFolder), 
                           formatPath(sraDownloadFolder))		

#Grab the location of the fasterq-dump script from the settings file
fasterq = system(sprintf("grep -oP \"fasterq\\s*=\\s*\\K([^\\s]+)\" %s/settings.txt", 
                                baseFolder), intern = T)
															
#Check if pigz is available instead of gzip for faster zipping
zipMethod = ifelse(length(suppressWarnings(
  system("command -v pigz", intern = T))) == 0, 
  "gzip", "pigz")

#Create temp folder
tempName = paste0("metaMixer_", as.integer(Sys.time()))
tempFolder = paste0(tempFolder, "/", tempName)
dir.create(tempFolder)

#Get the readcounts of previous files from the db in case the files are used again (saves time)
myConn = dbConnect(SQLite(), sprintf("%s/dataAndScripts/metaMixer.db", baseFolder))
readCounts = dbGetQuery(myConn, "SELECT f.*, d.readCount FROM seqFiles as f, seqData as d WHERE f.seqId = d.seqId") %>% 
  select(-folder) %>% mutate(fileSize = as.numeric(fileSize))
dbDisconnect(myConn)

newLogs = data.frame(timeStamp = as.integer(Sys.time()), actionId = 1, actionName = "Start Mixing")

tryCatch({
  
  # ---- Check the input file ----
  #*******************************
  
  if(verbose){
    cat(format(Sys.time(), "%H:%M:%S"),"- Check the input file for errors ... ")
  }
  
  #Read the input file and remove unwanted whitespace
  files = read_csv(inputFile, col_names = T, col_types = cols()) %>%  
    mutate(across(where(is.character), function(x) str_trim(x)))
  
  #Check that sum of RA = 1
  sumRA = ifelse(sum(files$relativeAbundance) != 1, "*** The sum of relative abundances is not 1", "")
  
  #Type combo check
  totalI = sum(str_detect(files$type, "i|I"))
  totalB = sum(str_detect(files$type, "b|B"))
  isoVsBack = ""
  if((totalI < 1 & totalB == 0) | 
     (totalI == 0 & totalB > 0 | 
      (totalB > 1) | 
      sum(totalI, totalB) != nrow(files))){
    isoVsBack = "*** Incorrect combination of samples. Choose any of the following:
  - Two or more isolate(I) files\n- One background(B) and one or more isolate(I) files"
  }
  
  
  #Check if files need to be downloaded
  SRAexists = ""
  if(any(colnames(files) %in% "getFromSRA")){
    files$SRAexists = sapply(
      files$getFromSRA, function(x){
        if(is.na(x)){
          return(T)
        } else {
          any(str_detect(readLines(
            sprintf("https://trace.ncbi.nlm.nih.gov/Traces/sra/sra.cgi?run=%s", x)), 
            "SRX"))
        }
      }
    )
    
    #Check if the files exist
    if(!all(files$SRAexists)){
      SRAexists = paste("*** The following files do not exist on SRA:\n    ",
                        paste(files$getFromSRA[!files$SRAexists], collapse = "     \n"))
    } else {
      # Add the future file locations to the list
      files = files %>% mutate(
        readFile = ifelse(is.na(getFromSRA), readFile, 
                          paste0(sraDownloadFolder, "/", getFromSRA, "_1.fastq.gz")),
        readFile2 = ifelse(is.na(getFromSRA), readFile2, 
                           paste0(sraDownloadFolder, "/", getFromSRA, "_2.fastq.gz"))
      )
      
      getFromSRA = unique(files$getFromSRA[!is.na(files$getFromSRA)])
    }
  } else {
    getFromSRA = NA
    files$getFromSRA = NA
  }
  
  
  files = files %>% 
    mutate(id = 1:n(), 
           sampleName = ifelse(sampleName == "", paste0("sample", 1:n()), sampleName)) %>% 
    pivot_longer(c(readFile, readFile2), values_to = "filePath") %>% 
    select(id, type, relativeAbundance, getFromSRA, filePath, sampleName) %>% 
    filter(filePath != "") %>% 
    mutate(modDate = file.info(filePath)$mtime %>% as.character(), 
           correctType = str_detect(filePath, "\\.fastq\\.gz$|\\.fastq$"),
           getFromSRA = !is.na(getFromSRA)
           )
  
  #Check if files are unique
  uniqueFiles = unique(files$filePath)
  allFiles = files$filePath
  
  uniqueFiles = ifelse(length(uniqueFiles) != length(allFiles), 
                       paste0("*** The following file names are duplicated:\n", 
                              paste(names(table(allFiles))[table(allFiles) > 1], collapse = "\n")), 
                       "")
  
  #Get all the missing files
  missing = c(files %>% filter(is.na(modDate) & !getFromSRA) %>% pull(filePath) %>% unique())
  
  missing = ifelse(length(missing) > 0, 
                   paste0("*** The following files are missing\n", paste(missing, collapse = "\n")), 
                   "")
  
  #Check for incorrect file types
  incorrectType = files %>% filter(!correctType) %>% pull(filePath) %>% unique()
  incorrectType = ifelse(length(incorrectType) > 0,paste0("*** The following files are not in fastq or fastq.gz format\n", 
                         paste(incorrectType, collapse = "\n")), 
                         "")
  files = files %>% select(-correctType)
  
  #Paste everything together
  errorMessage = c(sumRA, isoVsBack, uniqueFiles, missing, incorrectType, SRAexists)
  errorMessage = paste(errorMessage[errorMessage != ""], collapse = "\n\n")
  
  
  if(errorMessage != ""){
    newLogs = rbind(newLogs, list(as.integer(Sys.time()), 2, "Errors in input file, stop"))
    stop(paste0("Incorrect input file\n\n", errorMessage))
  }
  
  if(verbose){
    cat("none found\n")
  }
  newLogs = rbind(newLogs, list(as.integer(Sys.time()), 3, "Input file is valid"))
  
  
  # ---- Download from SRA if needed ----
  #**************************************
  if(!is.na(getFromSRA)){
    if(verbose){
      cat(format(Sys.time(), "%H:%M:%S"),"- Get data from SRA ... \n")
    }
    newLogs = rbind(newLogs, list(as.integer(Sys.time()), 10, "Get data from SRA"))
    
    for(SRR in getFromSRA){
      if(all(file.exists(sprintf(paste0("%s/%s_",1:2,".fastq.gz"), 
                                 sraDownloadFolder, SRR)))){
        cat("          ", SRR, "was already downloaded\n")
        newLogs = rbind(newLogs, list(as.integer(Sys.time()), 11, 
                                      paste(SRR, "was already downloaded")))
      } else {
        cat("\n          downloading and zipping", SRR, "...")
        system(sprintf(
          "%s %s -O %s -t %s/temp; find %s/%s_1.fastq %s/%s_2.fastq -execdir %s '{}' ';'",
          fasterq, SRR, sraDownloadFolder, sraDownloadFolder, 
          sraDownloadFolder, SRR, sraDownloadFolder, SRR, zipMethod), intern = F)
        cat("done\n")
        newLogs = rbind(newLogs, list(as.integer(Sys.time()), 12, 
                                      paste(SRR, "downloaded successfully")))
      }
     
    }
    
    #Add the modDates
    files = files %>% mutate(
      modDate = ifelse(is.na(modDate), file.info(filePath)$mtime %>% as.character() ,modDate)
    )
  }
  
  
  # ---- Get the read counts ----
  #*******************************
  
  #Add readcounts from previous runs
  files = files %>% mutate(fileSize = file.info(filePath)$size, 
                           fileName = str_extract(filePath, "[^/]+$"))
  files = files %>% left_join(readCounts, by = c("fileName", "modDate", "fileSize"))
  
  knownFiles = files %>% filter(!is.na(readCount)) %>% pull(fileName) %>% unique()
  
  if(length(knownFiles) > 0){
    if(verbose){
		cat(format(Sys.time(), "%H:%M:%S"),"- Use previous read-count for\n          ", 
		paste(knownFiles, collapse = "\n           "), "\n")
	}
    
	newLogs = rbind(
    newLogs, 
    setNames(data.frame(as.integer(Sys.time()), 4, 
	         paste("Use previous read-count for", paste(knownFiles, collapse = ", "))), 
             names(newLogs))
    )
  }
  
  
  #If no read counts yet, count them
  newFileIds = files %>% filter(is.na(readCount)) %>% pull(id) %>% unique()
  
  if(length(newFileIds) > 0){
    for(myId in newFileIds){
      
      myFile = files %>% filter(id == myId)
      
      if(verbose){
        cat(format(Sys.time(), "%H:%M:%S"),"- Counting number of reads in",myFile$fileName, "... ")
      }
  
      #Count the lines in the file (4 lines = 1 read)
      nReads = system(sprintf("zcat %s | wc -l", myFile$filePath[1]), intern = T) %>%
        as.integer()
      #If pair-end file, total reads id double from counted in one
      nReads = ifelse(nrow(myFile) == 2, nReads / 2, nReads / 4)
      
      
      files[files$id == myId, "readCount"] = nReads
      
      if(verbose){
        cat(nReads, "\n")
      }
  	newLogs = rbind(newLogs, list(as.integer(Sys.time()), 5, 
  	                              paste("Count reads for",paste(myFile$fileName, collapse = ", "))))
    }
   
  }
  
  
  # ---- Calculate the reads needed for the correct RA ----
  #********************************************************
  
  if(verbose){
    cat(format(Sys.time(), "%H:%M:%S"),"- Calculate the number of reads needed from each file ... ")
  }
  
  raData = files %>% group_by(id, type, relativeAbundance, readCount) %>% 
    summarise(.groups = 'drop')
  
  #Get min reads per % 
  rpp = min(raData$readCount / (raData$relativeAbundance *  100))
  
  #Calculate the total number of reads
  totalReads = sum(raData$relativeAbundance * 100 * rpp)
  
  #If a total is set, adjust the rpp
  nReadsM = raData %>% filter(type == "B" | type == "b") %>% pull(readCount)
  readLim = ifelse(readLimit == 0 & length(nReadsM) != 0, nReadsM, readLimit)
  if(readLim != 0){
    rpp = rpp * readLim / totalReads
  }
  
  #Caluclate the times each input file is needed
  raData = raData %>% mutate(readsNeeded = relativeAbundance * 100 * rpp,
                             fileNeeded = readsNeeded / readCount)
  
  if(verbose){
    cat("done\n")
  }
  newLogs = rbind(newLogs, list(as.integer(Sys.time()), 6, "Number of reads needed from each file calculated"))
  
  # ---- Filter and merge the files ----
  #*************************************
  toMerge = raData %>% left_join(files %>% select(id, filePath), by = "id") %>% 
    group_by(id, fileNeeded, readCount) %>% 
    summarise(file1 = filePath[1], 
              file2 = ifelse(is.na(filePath[2]), "", filePath[2]), .groups = 'drop')
  
  for(i in 1:nrow(toMerge)){
    
    fileNames = files %>% filter(id == toMerge$id[i]) %>% pull(fileName)
    if(verbose){
      cat(format(Sys.time(), "%H:%M:%S"),"- Extracting reads from\n          ", paste(fileNames, collapse = "\n           "), "\n")
    }
    
    fullFile = floor(toMerge$fileNeeded[i])
    partialFile = toMerge$fileNeeded[i] - floor(toMerge$fileNeeded[i])
    
    #Generate a full copy of the file with different ID if file needed more than once
    if(fullFile > 0 & toMerge$fileNeeded[i] != 1.0){
      for(j in 1:fullFile){
        system(sprintf(
          "%s in1=%s in2=%s out=stdout.fastq 2>/dev/null | awk 'NR %% 4 == 1{sub(/@/,\"@%i_\",$0);print;next}\
          NR %% 2 == 1{print \"+\";next}{print}' | %s -c > %s/tempFile%i_full%i.fastq.gz",
          reformatScript, toMerge$file1[i], toMerge$file2[i],
          j, zipMethod, tempFolder, i, j), intern = F)
      }
    } else if(toMerge$fileNeeded[i] == 1.0){
      system(sprintf(
        "%s in1=%s in2=%s out=%s/tempFile%i_partial.fastq.gz 2>/dev/null",
        reformatScript, toMerge$file1[i], toMerge$file2[i],
        tempFolder, i), intern = F)
    }
    
    #Filter the fraction of reads needed 
    partialReads = 0
    if(partialFile != 0){
      partialReads = system(sprintf(
        "%s --samplerate=%0.10f in1=%s in2=%s out=%s/tempFile%i_partial.fastq.gz 2>&1",
        reformatScript, partialFile, toMerge$file1[i], toMerge$file2[i],
        tempFolder, i), intern = T)
      partialReads = str_extract(partialReads, "\\d+(?=\\sreads\\s\\()")
      partialReads = as.integer(partialReads[!is.na(partialReads)])
    }
    
    toMerge$readCount[i] = floor(toMerge$fileNeeded[i]) * toMerge$readCount[i] + partialReads
    
    if(verbose){
      cat(format(Sys.time(),"%H:%M:%S ")," done\n")
    }
    newLogs = rbind(newLogs, list(as.integer(Sys.time()), 7, 
  	paste("Reads extracted from", paste(fileNames, collapse = ", "))))
    
  }
  
  #Add the number of used reads 
  raData = raData %>% left_join(toMerge %>% select(id, readsUsed = readCount), by = "id")
  files = files %>% left_join(toMerge %>% select(id, readsUsed = readCount), by = "id")
  
  #Merge the temp files into the final one
  if(verbose){
    cat(format(Sys.time(), "%H:%M:%S"),"- Merge all reads together and write final file ... ")
  }
  
  system(paste0("cat ", tempFolder, "/*.fastq.gz > ", outputFile))
  
  #Write the meta data as JSON (if requested)
  if(metaData){

    metaData = list(
      timestamp = Sys.time() %>% as.character(),
      inputFile = inputFile,
      outputFile = outputFile,
      readLimit = readLimit,
      totalReads = sum(raData$readsUsed),
      fileData = raData %>% select(-readsNeeded) %>% left_join(files %>% select(-type, -relativeAbundance, -readCount), by = "id") %>% 
        group_by(across(c(-filePath, -modDate, -fileSize, -fileName))) %>%
        summarise(fileName1 = fileName[1], 
                  filePath1 = filePath[1], 
                  fileName2 = ifelse(is.na(fileName[2]), "", fileName[2]), 
                  filePath2 = ifelse(is.na(filePath[2]), "", filePath[2]), .groups = "drop")
    )
  
    write_json(metaData, paste0(str_extract(outputFile, ".*(?=\\.fastq\\.gz$)"), "_metaData.json"), pretty = T)
    
  }
  
  
  # ---- Finish ----
  #*****************
  
  if(verbose){
    cat("done\n\n-- Total time to run script:", 
        round(difftime(Sys.time(), sTime, units = "mins"),2), "minutes --",
        "\n")
    
  }
  newLogs = rbind(newLogs, list(as.integer(Sys.time()), 8, 
  	paste("All reads merged and final file written to", outputFile)))
  
  
  # ---- Update the database ----
  #******************************
  
  #Open the connection to the DB
  myConn = dbConnect(SQLite(), sprintf("%s/dataAndScripts/metaMixer.db", baseFolder))
  
  #Get the next unique IDs
  # nextFileId = ifelse(nrow(readCounts) == 0, 1, max(readCounts$fileId) + 1)
  nextFileId = dbGetQuery(myConn, "SELECT max(fileId) as val FROM seqFiles")$val
  nextFileId = ifelse(is.na(nextFileId), 1, nextFileId + 1)
  nextSeqId = dbGetQuery(myConn, "SELECT max(seqId) as val FROM seqData")$val
  nextSeqId = ifelse(is.na(nextSeqId), 1, nextSeqId + 1)
  
  # save(newFileIds,files,raData,outputFile,nextFileId,nextSeqId, 
  #      file = sprintf("%s/dataAndScripts/test.Rdata", baseFolder))
  # load("dataAndScripts/test.Rdata")
  
  #Make a table with all files that are new and need to be inserted in seqData and seqFiles
  newFiles = rbind(
    files %>%  filter(id %in% newFileIds),
    list(id = 0, type = "M", relativeAbundance = 1.0, 
         getFromSRA = F, filePath = outputFile, 
         sampleName = str_match(outputFile, "([^/]+).fastq.gz$")[,2],
         modDate = file.info(outputFile)$mtime %>% as.character(), 
         fileSize = file.info(outputFile)$size, 
         fileName = str_extract(outputFile, "[^/]+.fastq.gz$"), 
         fileId = as.integer(NA),
         seqId = as.integer(NA),
         readCount = sum(raData$readsUsed),
         readsUsed = sum(raData$readsUsed))) %>% 
    group_by(id) %>% 
    mutate(filePath = str_remove(filePath, "[^/]+.fastq.gz$")) %>% ungroup()
  
  #Add the new seqId and fileId
  newFiles[is.na(newFiles$fileId),"fileId"] = 
    nextFileId:(nextFileId + sum(is.na(newFiles$fileId)) - 1)
  newSeqId = unique(unlist(newFiles[is.na(newFiles$seqId),"id"]))
  newSeqId = data.frame(id = newSeqId, 
                    newSeq = nextSeqId:(nextSeqId + length(newSeqId) - 1))
  newFiles = newFiles %>% left_join(newSeqId, by = "id") %>% 
    mutate(
      newFile = is.na(seqId),
      seqId = ifelse(newFile, newSeq, seqId)
    ) %>% select(-newSeq)
  
  #generate the data to fill the mixDetails table
  mixDetails = rbind(newFiles, files %>% filter(!id %in% newFileIds) %>% 
                       mutate(newFile = F)) %>% 
    left_join(raData %>% select(-relativeAbundance, -type, -readCount, -readsUsed), 
              by = "id") %>% mutate(runId = runId)
  
  #If the output file file will be overwritten, delete old one first from the database
  q = dbSendQuery(myConn,"PRAGMA foreign_keys = ON")
  dbClearResult(q)
  q = dbSendQuery(myConn,"DELETE FROM seqData WHERE seqId = 
  (SELECT seqId FROM seqFiles WHERE fileName = ? AND folder = ?)", 
                  params = list(newFiles$fileName[nrow(newFiles)], 
                                newFiles$filePath[nrow(newFiles)]))
  dbClearResult(q)
  
  #Insert the new files into seqData
  newSeqData = mixDetails %>% filter(newFile) %>% 
    group_by(seqId,sampleName,readCount) %>% 
    summarise(SRR = sampleName[getFromSRA][1],.groups = "drop")
  
  q = dbSendQuery(myConn, "INSERT INTO seqData (seqId,sampleName,readCount,SRR) VALUES(?,?,?,?)",
              params = list(newSeqData$seqId, newSeqData$sampleName, 
                            newSeqData$readCount, newSeqData$SRR))
  dbClearResult(q)
  
  #Insert the new files into seqFiles
  newFiles = newFiles %>% filter(newFile)
  q = dbSendQuery(myConn, "INSERT INTO \
                  seqFiles (fileId,seqId,fileName,folder,modDate,fileSize) \
                  VALUES(?,?,?,?,?,?)",
              params = list(newFiles$fileId, newFiles$seqId, newFiles$fileName, 
                            newFiles$filePath, newFiles$modDate, newFiles$fileSize))
  dbClearResult(q)
  
  #Add the meta data
  mixDetails = mixDetails %>% 
    select(runId, seqId,type,relativeAbundance,readsUsed) %>% distinct()
  
  q = dbSendQuery(myConn, "INSERT INTO mixDetails \
                 (runId,seqId,type,relativeAbundance,nReadsUsed) \
                 VALUES(?,?,?,?,?)",
                  params = list(mixDetails$runId, mixDetails$seqId, toupper(mixDetails$type),
                                mixDetails$relativeAbundance, mixDetails$readsUsed))
  dbClearResult(q)
  dbDisconnect(myConn)
  
  newLogs = rbind(newLogs, list(as.integer(Sys.time()), 9, 
                                "Database successfully updated"))

}, 
finally = {
  #Submit the logs, even in case of error so we know where things went wrong
  
  newLogs$runId = runId
  newLogs$tool = "metaMixer.R"

  myConn = dbConnect(SQLite(), sprintf("%s/dataAndScripts/metaMixer.db", baseFolder))
  q = dbSendStatement(myConn, "INSERT INTO logs (runId,tool,timeStamp,actionId,actionName) VALUES (?,?,?,?,?)",
                      params = unname(as.list(newLogs %>% select(runId,tool,timeStamp,actionId,actionName))))
  dbClearResult(q)
  dbDisconnect(myConn)
  
  #Remove temp files
  system(paste("rm -r", tempFolder))
})
