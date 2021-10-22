#**************************
# ---- SEQ2MGS Setup ----
#**************************

#Check R version
if(as.integer(R.version$major) < 4){
  warning(paste0("R version 4.0 or higher is recommended.\n",
      "Currently ", R.version$version.string, " is the default.\n",
      " If your system has multiple R versions change the default to 4.0+.\n",
      " In case of unexpected errors, update R to the latest version\n"))
}

#Check R packages
packages = c("tidyverse", "RSQLite", "httr", "jsonlite")
installed = packages %in% installed.packages()[,1]

if(!all(installed)){
  stop(paste("The following R packages are not installed:\n",
             paste(packages[!installed], collapse = ", ")))
}

if(!stringr::str_detect(as.character(packageVersion("dplyr")), "^1")){
  stop("The dplyr package needs to be version 1.0+")
}

#Check dependencies ($PATH in R can be different)
for(dep in c("reformat.sh")){
  if(system(sprintf("if [ -z `command -v %s` ]; then echo ERROR; else echo OK; fi",
                    dep), 
            intern = T) == "ERROR"){
    stop(paste(ifelse(dep == "reformat.sh", "The BBmap package", "The SRAtoolkit"), 
               "was not detected in the $PATH variable within R.\n",
               " make sure the R environment $PATH is setup correctly\n"))
  }
}


