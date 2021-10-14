#!/usr/bin/env Rscript
args = commandArgs(trailingOnly=TRUE)

#Load packages
suppressPackageStartupMessages(library(tidyverse))
suppressPackageStartupMessages(library(jsonlite))
suppressPackageStartupMessages(library(RSQLite))
suppressPackageStartupMessages(library(httr))


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

#Variables from seq2mgs.sh script
baseFolder = formatPath(as.character(args[[1]]))
inputFile = as.character(args[[2]])
outputFile = as.character(args[[3]])
minBases = max(as.integer(args[[4]]), 0, na.rm = T)
maxBases = min(as.integer(args[[5]]), Inf, na.rm = T)
metaData = as.logical(args[[6]])
verbose = as.logical(args[[7]])
tempFolder = formatPath(as.character(args[[8]]))
runId = as.integer(args[[9]])
minBackBases = max(as.integer(args[[10]]), 0, na.rm = T)
maxBackBases = min(as.integer(args[[11]]), Inf, na.rm = T)
defGenomeSize = as.integer(args[[12]])
oversample = T 

#Grab the location of the sraDownloadFolder from the settings file
sraDownloadFolder = suppressWarnings(
  system(sprintf("grep -oP \"sraDownloadFolder\\s*=\\s*\\K([^\\s]+)\" %s/settings.txt",
                 baseFolder), intern = T))
sraDownloadFolder = ifelse(length(sraDownloadFolder) == 0, "", sraDownloadFolder)

#Check if the temp / sraDownloadFolder are the default ones
if(!str_detect(tempFolder, "^\\/")){
  tempFolder = paste0(baseFolder, "/", tempFolder)
}
if(!dir.exists(sraDownloadFolder)){
  dir.create(paste0(baseFolder, "/", "SRAdownloads"), showWarnings = F)
  sraDownloadFolder = paste0(baseFolder, "/", "SRAdownloads")
}

#Grab the seq2mgsMaxFileN from the settings file
maxNfiles = as.integer(system(sprintf("grep -oP \"seq2mgsMaxResample\\s*=\\s*\\K([^\\s]+)\" %s/settings.txt", 
                         baseFolder), intern = T))
															
#Check if pigz is available instead of gzip for faster zipping
zipMethod = ifelse(length(suppressWarnings(
  system("command -v pigz", intern = T))) == 0, 
  "gzip", "pigz")

#Create temp folder
tempName = paste0("seq2mgs_", as.integer(Sys.time()))
tempFolder = paste0(tempFolder, "/", tempName)
dir.create(tempFolder, showWarnings = F)

#Get the readcounts of previous files from the db in case the files are used again (saves time)
myConn = dbConnect(SQLite(), sprintf("%s/dataAndScripts/seq2mgs.db", baseFolder))
readCounts = dbGetQuery(
  myConn, 
  "SELECT f.*, d.readCount, d.readLength FROM seqFiles as f, seqData as d WHERE f.seqId = d.seqId") %>% 
  select(-folder) %>% mutate(fileSize = as.numeric(fileSize))
dbDisconnect(myConn)

newLogs = data.frame(timeStamp = as.integer(Sys.time()), actionId = 1, 
                     actionName = "Start Mixing")
finalMessage = ""

tryCatch({
  
  # ---- Check the input file ----
  #*******************************
  
  if(verbose){
    cat(format(Sys.time(), "%H:%M:%S"),"- Check the input file for errors ... ")
  }
  
  #Read the input file and remove unwanted whitespace
  tryCatch({
    files = read_csv(inputFile, col_names = T, col_types = cols()) %>%  
      mutate(across(where(is.character), function(x) str_trim(x)))
  },
  warning = function(x){
    stop("\n\nThe CSV file is not in a valid format\n\n")
  },
  error = function(x){
    stop("\n\nThe CSV file is not in a valid format\n\n")
  })
  
  allCols = colnames(files)
  
  reqCols = ""
  #Check the columns needed
  if(! "type" %in% allCols){
    reqCols = " type column must be present\n"
  }
  
  if(!any(c("relativeAbundance", "coverage") %in% allCols)){
    reqCols = " relativeAbundance or coverage must be present\n"
  }
  
  if(all(c("relativeAbundance", "coverage") %in% allCols)){
    reqCols = " relativeAbundance and coverage cannot be present at the same time\n"
  }
  
  if(!any(c("readFile", "getFromSRA") %in% allCols)){
    reqCols = " readFile and/or getFromSRA must be present"
  } else if(!"readFile" %in% allCols){
    files$readFile = NA_character_
    files$readFile2 = NA_character_
  }
  
  if(reqCols != ""){
    reqCols = paste0("*** Issues with columns:\n", reqCols)
    newLogs = rbind(newLogs, list(as.integer(Sys.time()), 2, "Errors in input file, stop"))
    stop(paste0("Incorrect input file\n\n", reqCols))
  }
  
  if(! "sampleName" %in% allCols){
    files$sampleName = NA_character_
  }
  
  #Type combo check
  if(!all(str_detect(files$type, "^i|^I|^b|^B"))){
    isoVsBack = "*** Incorrect sample types. Either i, I, isolate or b, B, background"
  } else{
    files$type = ifelse(str_detect(files$type, "^i|^I"), "i", "b")
    totalI = sum(files$type == "i")
    totalB = sum(files$type == "b")
    isoVsBack = ""
    if((totalI < 1 & totalB == 0) | 
       (totalI == 0 & totalB > 0 | 
        (totalB > 1) | 
        sum(totalI, totalB) != nrow(files))){
      isoVsBack = "*** Incorrect combination of samples. Choose any of the following:
  - Two or more isolate(I) files\n- One background(B) and one or more isolate(I) files"
    }
  }
  
  #Check if limits are used correctly
  sumRA = ""
  if("coverage" %in% allCols){
    if(minBases > 0 | maxBases < Inf){
      finalMessage = paste(
        finalMessage, 
        "  NOTE: The set limits do not apply here, use the a|b arguments instead\n")
    }
    
    if(is.na(sum(files$coverage[files$type != "b"]))){
      sumRA = "*** The coverage of each isolate must be a numeric value >= 0"
    }
    
    files = files %>% 
      mutate(coverage = ifelse(type == "b", NA, coverage))
    
  } else {
    
    #Calculate the background RA if present
    files = files %>% 
      mutate(relativeAbundance = ifelse(str_detect(type, "i|I"), relativeAbundance, 
                                        1 - sum(relativeAbundance[str_detect(type, "i|I")])))
    #Check that sum of RA = 1
    sumRA = ifelse(sum(files$relativeAbundance) != 1, 
                   "*** The sum of relative abundances is not 1", "")
    
    if(minBackBases > 0 | maxBackBases < Inf){
      finalMessage = paste(
        finalMessage, 
        "  NOTE: The set limits do not apply here, use the u|l arguments instead\n")
    }
  }
 
  #Check the genome size
  if("genomeSize" %in% allCols){
    files = files %>% 
      mutate(
        genomeSize = as.integer(genomeSize),
        genomeSize = case_when(
          type == "b" ~ NA_integer_,
          is.na(genomeSize) ~ defGenomeSize,
          TRUE ~ genomeSize)
        )
  } else {
    files$genomeSize = as.integer(ifelse(files$type == "b", NA, defGenomeSize))
    finalMessage = paste(
      finalMessage, 
      "  NOTE: the default genome size estimation of ", round(defGenomeSize / 1000000, 3), 
      "Mbp\n   was used to calculate the relative abundance or coverage\n")
  }
  
  #Check if every input has a file / SRA assigned
  pickFile = ""
  if(any(is.na(files$getFromSRA) & is.na(files$readFile) & is.na(files$readFile2)) |
     any(!is.na(files$getFromSRA) & (!is.na(files$readFile) | !is.na(files$readFile2)))){
    pickFile = "*** Each file needs either a path to a local file OR an SRA accession\n"
  }
  
  #Check if files need to be downloaded
  SRAexists = ""
  if(any(colnames(files) %in% "getFromSRA")){
    
    cat("\n            Checking if SRA files are available ... ")
    
    #Check which files have been downloaded and if paired or single
    alreadyDownloaded = data.frame(
      getFromSRA = list.files(sraDownloadFolder, pattern = ".fastq.gz") %>% 
        str_remove(".fastq.gz$|_\\d.fastq.gz")) %>% 
      group_by(getFromSRA) %>% summarise(SRAexists = n())
    
    files = files %>% left_join(alreadyDownloaded, by = "getFromSRA")
    
    #Look up the SRR for the ones missing
    toCheck = !is.na(files$getFromSRA) & is.na(files$SRAexists)
    sraToolsPresent = system("command -v fastq-dump", ignore.stdout=T) == 0
    
    if(sum(toCheck) > 0 & sraToolsPresent){
      
      files$SRAexists[toCheck] = 
        sapply(files$getFromSRA[toCheck], function(x){
          system(sprintf("fastq-dump -X 1 -Z --split-spot %s 2>/dev/null | wc -l",
                         x),
                 intern = T)
        }) %>% as.integer() / 4
      
      #Check if the files exist
      if(!all(files$SRAexists > 0, na.rm = T)){
        SRAexists = paste("*** The following files do not exist on SRA:\n    ",
                          paste(files$getFromSRA[files$SRAexists == 0 &
                                                   !is.na(files$SRAexists)], 
                                collapse = "\n     "))
      } 
    } else if(sum(toCheck) > 0 & !sraToolsPresent){
      SRAexists = "*** The sraToolkit was not found and the requested files cannot be downloaded"
    }
    
    if(all(files$SRAexists > 0, na.rm = T)){
      # Add the future file locations to the list
      files = files %>% mutate(
        readFile = as.character(readFile),
        readFile = case_when(
          is.na(SRAexists) ~ readFile, 
          SRAexists == 1 ~ paste0(sraDownloadFolder, "/", getFromSRA, ".fastq.gz"),
          TRUE ~ paste0(sraDownloadFolder, "/", getFromSRA, "_1.fastq.gz")),
        readFile2 = case_when(
          is.na(SRAexists) ~ readFile2, 
          SRAexists == 2 ~ paste0(sraDownloadFolder, "/", getFromSRA, "_2.fastq.gz"),
          TRUE ~ NA_character_)
      )
      
      getFromSRA = unique(files$getFromSRA[!is.na(files$getFromSRA)])
      getFromSRA = getFromSRA[!getFromSRA %in% alreadyDownloaded$getFromSRA]
    }
    
    cat("done\n           ")
  } else {
    getFromSRA = NA
    files$getFromSRA = NA
  }
  

  files = files %>% 
    mutate(id = 1:n()) %>% 
    pivot_longer(c(readFile, readFile2), values_to = "filePath") %>% 
    select(id, type, any_of(c("relativeAbundance", "coverage", "genomeSize")), 
           getFromSRA, filePath, sampleName) %>% 
    filter(filePath != "") %>% 
    mutate(modDate = file.info(filePath)$mtime %>% as.character(), 
           correctType = str_detect(filePath, "\\.fastq\\.gz$|\\.fastq$"),
           getFromSRA = ifelse(getFromSRA == "", NA, getFromSRA)
           )
  
  #Check if files are unique
  uniqueFiles = unique(files$filePath)
  allFiles = files$filePath
  
  uniqueFiles = ifelse(length(uniqueFiles) != length(allFiles), 
                       paste0("*** The following file names are duplicated:\n", 
                              paste(names(table(allFiles))[table(allFiles) > 1], 
                                    collapse = "\n")), 
                       "")
  
  #Get all the missing files
  missing = c(files %>% filter(is.na(modDate) & is.na(getFromSRA)) %>% 
                pull(filePath) %>% unique())
  
  missing = ifelse(length(missing) > 0, 
                   paste0("*** The following files are missing\n", 
                          paste(missing, collapse = "\n")), 
                   "")
  
  #Check for incorrect file types
  incorrectType = files %>% filter(!correctType) %>% pull(filePath) %>% unique()
  incorrectType = ifelse(length(incorrectType) > 0,
                         paste0("*** The following files are not in fastq or fastq.gz format\n", 
                         paste(incorrectType, collapse = "\n")), "")
  files = files %>% select(-correctType)
  
  
  #Paste everything together
  errorMessage = c(sumRA, isoVsBack, uniqueFiles, pickFile, missing, 
                   incorrectType, SRAexists)
  errorMessage = paste(errorMessage[errorMessage != ""], collapse = "\n\n")
  
  
  if(errorMessage != ""){
    newLogs = rbind(newLogs, list(as.integer(Sys.time()), 2, "Errors in input file, stop"))
    stop("\n\nIncorrect input file\n\n", errorMessage, "\n\n")
  }
  
  if(verbose){
    cat("none found\n")
  }
  newLogs = rbind(newLogs, list(as.integer(Sys.time()), 3, "Input file is valid"))
  
  
  # ---- Download from SRA if needed ----
  #**************************************
  if(any(!is.na(getFromSRA))){
    if(verbose){
      cat(format(Sys.time(), "%H:%M:%S"),"- Get data from SRA ... \n")
    }
    newLogs = rbind(newLogs, list(as.integer(Sys.time()), 10, "Get data from SRA"))
    
    for(SRR in getFromSRA){
      if(length(list.files(sraDownloadFolder, pattern = SRR)) > 0){
        cat("          ",SRR, ": already downloaded\n")
        newLogs = rbind(newLogs, list(as.integer(Sys.time()), 11, 
                                      paste(SRR, "was already downloaded")))
      } else {
        cat("          ",SRR, ": downloading ... ")
        system(sprintf(
          "fasterq-dump %s -O %s -t %s/temp 2>/dev/null", 
          SRR, sraDownloadFolder, sraDownloadFolder), intern = F)
        
        cat("zipping ... ")
        if(nrow(files %>% filter(getFromSRA == SRR)) == 1){
          system(sprintf("%s %s/%s.fastq",
            zipMethod, sraDownloadFolder, SRR), intern = F)
        } else {
          system(sprintf(
            "find %s/%s_1.fastq %s/%s_2.fastq -execdir %s '{}' ';'",
            sraDownloadFolder, SRR, sraDownloadFolder, SRR, zipMethod), intern = F)
        }
        
        
        cat("done\n")
        newLogs = rbind(newLogs, list(as.integer(Sys.time()), 12, 
                                      paste(SRR, "downloaded successfully")))
      }
     
    }
    
    #Add the modDates
    files = files %>% mutate(
      modDate = ifelse(is.na(modDate), file.info(filePath)$mtime %>% 
                         as.character() ,modDate)
    )
  }
  
  
  # ---- Get the read counts + length ----
  #***************************************
  
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
  
  
  #If no read counts yet, count them + mean length
  newFileIds = files %>% filter(is.na(readCount)) %>% pull(id) %>% unique()
  
  if(length(newFileIds) > 0){
    for(myId in newFileIds){
      
      myFile = files %>% filter(id == myId)
      
      if(verbose){
        cat(format(Sys.time(), "%H:%M:%S"),"- Counting reads in",
            myFile$fileName[1], "...\n            ")
      }
  
      #Count the lines in the file (4 lines = 1 read)
      nReads = system(sprintf("zcat %s | wc -l", myFile$filePath[1]), intern = T) %>%
        as.integer()
      #If pair-end file, total reads id double from counted in one
      nReads = ifelse(nrow(myFile) == 2, nReads / 2, nReads / 4)
      
      
      files[files$id == myId, "readCount"] = nReads
      
      #Add the average read count based on the first 10000 reads
      avgLength = sapply(readLines(myFile$filePath[1], 40000)[seq(2, 40000, 4)],
             nchar, USE.NAMES = F) %>% mean(na.rm = T)
      files[files$id == myId, "readLength"] = avgLength
      
      if(verbose){
        cat(nReads, "(mean length ~", avgLength, ")\n")
      }
  	newLogs = rbind(newLogs, 
  	                list(as.integer(Sys.time()), 5, 
  	                     paste("Count reads for",paste(myFile$fileName[1], 
  	                                                   collapse = ", "))))
    }
   
  }
  
  
  # ---- Calculate the reads needed for the correct RA / coverage ----
  #*******************************************************************
  
  if(verbose){
    cat(format(Sys.time(), "%H:%M:%S"),
        "- Calculate the number of reads needed from each file ... ")
  }
  
  raData = files %>% 
    select(any_of(c("id", "type", "relativeAbundance", "readCount", 
                    "readLength", "genomeSize", "coverage"))) %>% 
    distinct()
  
  #Make calculations based on scenario...
  if("coverage" %in% colnames(raData)){ ### COVERAGE BASED CALCULATIONS
    
    #Calculate the number of reads for coverage
    raData = raData %>% mutate(
      coverage = ifelse(type == "b", NA, coverage),
      readsNeeded = genomeSize * coverage / readLength,
      readsNeeded = ifelse(type == "b", readCount - sum(readsNeeded, na.rm = T), readsNeeded)
    )
    
    #Add or remove background reads based on limits
    if(any(raData$type == "b")){
      backBases = raData$readsNeeded[raData$type == "b"] * raData$readLength[raData$type == "b"]
      backBases = case_when(
        backBases < minBackBases ~ minBackBases,
        backBases > maxBackBases ~ maxBackBases,
        TRUE ~ backBases
      )
      raData$readsNeeded[raData$type == "b"] = backBases /  raData$readLength[raData$type == "b"]
    }
    
    raData = raData %>% mutate(fileNeeded = readsNeeded / readCount)
    
  } else if(any(raData$type == "b")){ ### RA WITH BACKGROUND
    
    if(T){
      raData = raData %>% 
        mutate(genomeCorrection = genomeSize / min(genomeSize, na.rm = T))
      raData$genomeCorrection[raData$type == "b"] = 1
    } else {
      raData$genomeCorrection = 1
    }
    
    sumBases = raData %>% filter(type == "b") %>% 
      mutate(val = readLength * readCount) %>% pull(val)
    totalBases = case_when(
      sumBases < minBases ~ minBases,
      sumBases > maxBases ~ maxBases,
      TRUE ~ sumBases
    )
    
    #Get the final read counts
    raData = raData %>% 
      mutate(
        readsNeeded = as.integer(totalBases * relativeAbundance * genomeCorrection/ readLength),
        fileNeeded = readsNeeded / readCount
      )

  } else { ### RA WITHOUT BACKGROUND
    
    #Correct for genome size (larger needs more reads for same RA)
    if(T){
      raData$genomeCorrection = 1 / (raData$genomeSize / min(raData$genomeSize))
    } else {
      raData$genomeCorrection = 1
    }
    
    #Find the file with the fewest bases available for the RA
    readCorrection = raData %>% mutate(
      val = readCount * readLength * relativeAbundance / genomeCorrection
    ) %>% filter(val == max(val)) %>% slice(1) %>% 
      mutate(val = readCount * readLength * genomeCorrection / relativeAbundance) %>% 
      pull(val)
    
    #Adjust the other file's bases needed + correct for genome
    raData = raData %>% mutate(
      readsNeeded = readCorrection * relativeAbundance / (readLength * genomeCorrection)
    )
    
    #Adjust the read counts based on min - max if set
    sumBases = sum(raData$readsNeeded * raData$readLength)
    totalBases = case_when(
      sumBases < minBases ~ minBases,
      sumBases > maxBases ~ maxBases,
      TRUE ~ sumBases
    )
    
    #Get the final read counts
    raData$readsNeeded = raData$readsNeeded * totalBases / sumBases
    raData$fileNeeded = raData$readsNeeded / raData$readCount
    raData$readsNeeded = as.integer(raData$readsNeeded)

  }
  
  if(verbose){
    cat("done\n")
  }
  newLogs = rbind(newLogs, list(as.integer(Sys.time()), 6, 
                                "Number of reads needed from each file calculated"))
  
  raData = raData %>% select(-any_of("genomeCorrection")) 
  
  #Check if the file times limit is not crossed
  check = raData$id[raData$fileNeeded > maxNfiles]
  if(length(check) > 0){
    check = files %>% filter(id %in% check) %>% pull(fileName)
    stop("\n\nWith the current input settings, the files below would require",
         " being resampled >", maxNfiles, " times which would take a very long time.",
         " If you really want to do this, you can adjust the 'seq2mgsMaxResample'",
         " parameter in the settings.txt file and run the script again.\n\nFiles: ",
         paste(check, collapse = ", "), "\n\nPotiential causes:\n",
         "  - Too large a coverage or genome size\n",
         "  - Very small file sizes (i.e. low amount of reads)\n\n")
  }

  # ---- Filter and merge the files ----
  #*************************************
  toMerge = raData %>% filter(fileNeeded > 0) %>% 
    left_join(files %>% select(id, filePath), by = "id") %>% 
    group_by(id, fileNeeded, readCount) %>% 
    summarise(file1 = filePath[1], 
              file2 = ifelse(is.na(filePath[2]), "", filePath[2]), .groups = 'drop')
  
  for(i in 1:nrow(toMerge)){
    
    fileNames = files %>% filter(id == toMerge$id[i]) %>% pull(fileName)
    if(verbose){
      cat(format(Sys.time(), "%H:%M:%S"),"- Extracting reads from\n          ", 
          paste(fileNames, collapse = "\n           "), "\n")
    }
    
    fullFile = floor(toMerge$fileNeeded[i])
    partialFile = toMerge$fileNeeded[i] - floor(toMerge$fileNeeded[i])
    
    #Generate a full copy of the file with different ID if file needed more than once
    if(fullFile > 0){
      for(j in 1:fullFile){
        system(sprintf(
          "rename.sh in=%s in2=%s out=%s/tempFile%i_full%i.fastq.gz int=t prefix=fileId%i_full_%i_read 2>/dev/null",
          toMerge$file1[i], toMerge$file2[i],
          tempFolder, i, j, toMerge$id[i], j), intern = F)
      }
    }
    
    #Filter the fraction of reads needed 
    partialReads = 0
    if(partialFile != 0){
      partialReads = system(sprintf(
        "reformat.sh --samplerate=%0.10f in1=%s in2=%s out=%s/partial.fastq.gz 2>&1",
        partialFile, toMerge$file1[i], toMerge$file2[i], tempFolder), 
        intern = T)
      partialReads = str_extract(partialReads, "\\d+(?=\\sreads\\s\\()")
      partialReads = as.integer(partialReads[!is.na(partialReads)])
      
      system(sprintf(
        "rename.sh in=%s/partial.fastq.gz out=%s/tempFile%i_partial.fastq.gz ow=t prefix=fileId%i_partial_read 2>&1",
        tempFolder, tempFolder, i, toMerge$id[i]), intern = T)
      
      system(sprintf("rm %s/partial.fastq.gz", tempFolder), intern = T)
    }
    
    toMerge$readCount[i] = floor(toMerge$fileNeeded[i]) * toMerge$readCount[i] + 
      partialReads
    
    if(verbose){
      cat(format(Sys.time(),"%H:%M:%S ")," done\n")
    }
    newLogs = rbind(newLogs, list(as.integer(Sys.time()), 7, 
  	paste("Reads extracted from", paste(fileNames, collapse = ", "))))
    
  }
  
  #Add the number of used reads 
  raData = raData %>% left_join(toMerge %>% select(id, readsUsed = readCount), by = "id") %>% 
    mutate(readLength = round(readLength, 2))
  files = files %>% left_join(toMerge %>% select(id, readsUsed = readCount), by = "id")
  
  #Merge the temp files into the final one
  if(verbose){
    cat(format(Sys.time(), "%H:%M:%S"),"- Merge & shuffle all reads and write final file ... ")
  }
  
  system(paste0("cat ", tempFolder, "/*.fastq.gz > ", outputFile))
  system(sprintf(
    "shuffle.sh in=%s out=%s overwrite=t 2>&1",
    outputFile, outputFile), intern = T)
  
  #Write the meta data as JSON (if requested)
  if(metaData){

    if("relativeAbundance" %in% colnames(raData)){
      limits = list(minBases = minBases, maxBases = maxBases)
    } else {
      if("b" %in% raData$type){
        limits = list(minBackBases = minBackBases, maxBackBases = maxBackBases)
      } else {
        limits = list()
      }
    }
    
    metaData = list(
      timestamp = Sys.time() %>% as.character(),
      inputFile = inputFile,
      outputFile = outputFile,
      totalReads = sum(raData$readsUsed),
      estimatedBases = round(sum(raData$readsUsed * raData$readLength),0),
      limits = limits,
      fileData = raData %>% select( -readsNeeded, -readsUsed) %>% 
        left_join(
          files %>% 
            select(-type, -any_of(c("relativeAbundance", "coverage", "genomeSize")), 
                                 -readCount, -readLength, -fileId), by = "id") %>% 
        group_by(across(c(-filePath, -modDate, -fileSize, -fileName))) %>%
        summarise(fileName1 = fileName[1], 
                  filePath1 = filePath[1], 
                  fileName2 = ifelse(is.na(fileName[2]), "", fileName[2]), 
                  filePath2 = ifelse(is.na(filePath[2]), "", filePath[2]), 
                  .groups = "drop") %>% 
        select(seqId, type:fileNeeded, readsUsed, sampleName, 
               SRR = getFromSRA, fileName1:filePath2) %>% 
        mutate(type = ifelse(type == "i", "isolate", "background"))
    )
  
    write_json(metaData, paste0(str_extract(outputFile, ".*(?=\\.fastq\\.gz$)"), 
                                "_metaData.json"), pretty = T)
    
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
  myConn = dbConnect(SQLite(), sprintf("%s/dataAndScripts/seq2mgs.db", baseFolder))
  
  #Get the next unique IDs
  # nextFileId = ifelse(nrow(readCounts) == 0, 1, max(readCounts$fileId) + 1)
  nextFileId = dbGetQuery(myConn, "SELECT max(fileId) as val FROM seqFiles")$val
  nextFileId = ifelse(is.na(nextFileId), 1, nextFileId + 1)
  nextSeqId = dbGetQuery(myConn, "SELECT max(seqId) as val FROM seqData")$val
  nextSeqId = ifelse(is.na(nextSeqId), 1, nextSeqId + 1)
  
  #Make a table with all files that are new and need to be inserted in seqData and seqFiles
  newFiles = bind_rows(
    files %>%  filter(id %in% newFileIds),
    list(id = 0, type = "M",
         getFromSRA = NA, filePath = outputFile, 
         sampleName = str_match(outputFile, "([^/]+).fastq.gz$")[,2],
         modDate = file.info(outputFile)$mtime %>% as.character(), 
         fileSize = file.info(outputFile)$size, 
         fileName = str_extract(outputFile, "[^/]+.fastq.gz$"), 
         fileId = as.integer(NA),
         seqId = as.integer(NA),
         readCount = sum(raData$readsUsed),
         readLength = raData$readLength[1],
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
  mixDetails = bind_rows(newFiles, files %>% filter(!id %in% newFileIds) %>% 
                       mutate(newFile = F)) %>% 
    left_join(raData %>% 
                select(-any_of(c("relativeAbundance", "coverage", "genomeSize")), 
                       -type, -readCount, -readLength, -readsUsed), 
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
    group_by(seqId,sampleName,readCount, readLength) %>% 
    summarise(SRR = getFromSRA[1],.groups = "drop")
  
  q = dbSendQuery(
    myConn, 
    "INSERT INTO seqData (seqId,sampleName,readCount,readLength,SRR) VALUES(?,?,?,?,?)",
    params = list(newSeqData$seqId, newSeqData$sampleName,
                  newSeqData$readCount, newSeqData$readLength, newSeqData$SRR))
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
  if("relativeAbundance" %in% colnames(raData)){
    mixDetails = mixDetails %>% 
      select(runId, seqId,type,relativeAbundance,readsUsed) %>% distinct()
    
    q = dbSendQuery(myConn, "INSERT INTO mixDetails \
                 (runId,seqId,type,relativeAbundance,nReadsUsed) \
                 VALUES(?,?,?,?,?)",
                    params = list(mixDetails$runId, mixDetails$seqId, toupper(mixDetails$type),
                                  mixDetails$relativeAbundance, mixDetails$readsUsed))
    dbClearResult(q)
    dbDisconnect(myConn)
  } else {
    mixDetails = mixDetails %>% 
      select(runId, seqId,type,coverage,readsUsed) %>% distinct()
    
    q = dbSendQuery(myConn, "INSERT INTO mixDetails \
                 (runId,seqId,type,coverage,nReadsUsed) \
                 VALUES(?,?,?,?,?)",
                    params = list(mixDetails$runId, mixDetails$seqId, toupper(mixDetails$type),
                                  mixDetails$coverage, mixDetails$readsUsed))
    dbClearResult(q)
    dbDisconnect(myConn)
  }
 
  
  newLogs = rbind(newLogs, list(as.integer(Sys.time()), 9, 
                                "Database successfully updated"))

}, 

finally = {
  #Submit the logs, even in case of error so we know where things went wrong
  
  newLogs$runId = runId
  newLogs$tool = "seq2mgs.R"

  myConn = dbConnect(SQLite(), sprintf("%s/dataAndScripts/seq2mgs.db", baseFolder))
  q = dbSendStatement(
    myConn, 
    "INSERT INTO logs (runId,tool,timeStamp,actionId,actionName) VALUES (?,?,?,?,?)",
    params = unname(as.list(newLogs %>% 
                              select(runId,tool,timeStamp,actionId,actionName))))
  dbClearResult(q)
  dbDisconnect(myConn)
  
  #Remove temp files
  system(paste("rm -r", tempFolder))
  
  if(verbose & finalMessage != ""){
    cat("\nMessages:\n", finalMessage)
  }
  
})
