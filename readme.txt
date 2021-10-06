########## SEQ2MGS ##########
#############################
   Developed by PJ Van Camp
     vancampn@mail.uc.edu

--- SETUP.SH ---
Run the setup.sh script to verify all dependencies and to test the pipeline.
THe first time a database will be created in the dataAndScripts folder

Arguments [h|t]
 -h Read the help documentation
 -t Run pipeline tests with dummy data (will take bit longer)

The following software needs to be installed:
- SQLite3 
  * Precompiled 32-bit version: https://www.sqlite.org/download.html
  * Precompiled 64-bit version: https://github.com/boramalper/sqlite3-x64/releases
- R version 4.0+
  * Packages: RSQLite, tidyverse (dplyr 1.0+), jsonlite, httr
  * Precompiled versions: https://www.r-project.org/ 
    OR: https://docs.rstudio.com/resources/install-r/
- bbmap
  * https://jgi.doe.gov/data-and-tools/bbtools/bb-tools-user-guide/installation-guide/
- sratoolkit
  * https://github.com/ncbi/sra-tools
  * Make sure to configure the tool before using it!
    https://github.com/ncbi/sra-tools/wiki/03.-Quick-Toolkit-Configuration
  NOTE: if you run this under a different user or root, you need to configure again
  * The default location for saving the data is SRAdownloads/ in the SEQ2MGS folder
    This can be changed in the settings.txt file

Optional software
- pigz
  * If installed, faster zipping with multi-cores
   
IMPORTANT: Make sure all dependencies are in the $PATH variable
	i.e. Rscript, sqlite3, bbmap/ and sratoolkit/

-- END SETUP.SH ---


--- SEQ2MGS.SH ---
Mix multiple isolate fastq files together to create artificial metagenomes 

Arguments [h|i|o|l|u|a|b|d|m|t|f|v]
 -h Read the help documentation
 
# Required
 -i The input file (.csv) containing all samples to be mixed (details see below)
 -o The location to save the output file. Filename should end with a fastq.gz extension

# Optional
 -d (optional) Change default value of the genomeSize column in the input file. 
     Default can also be changed in the settings.txt file
 -m (optional) TRUE or FALSE. 
     Generate a meta-data JSON file in the same folder as the output file.
     Default can be changed in the settings.txt file
 -f (optional) If set, force overwriting an existing output file
 -v (optional) TRUE or FALSE. Progress is posted to stdout when TRUE.
     Default can be changed in the settings.txt file
 
# Mix-in based on relative abundance (optional)
 -l (optional) The min number of bases the mixed file should contain. 
     By default, the number of bases in the background file is chosen.
     If no background file is present, the limit is the max sum of 
	 the fractions needed from each isolate file.
 -u (optional) The max number of bases the mixed file should contain. 
     By default, the number of bases in the background file is chosen.
     If no background file is present, the limit is the sum of 
	 the fractions needed from each isolate file.
	 
# Mix-in based on coverage (optional)
 -a (optional) The min number of bases the background should contain. 
     By default, the number of bases is the difference between the 
	 bases used for the isolates and the bases in the background
 -b (optional) The max number of bases the background should contain. 
     By default, the number of bases is the difference between the 
	 bases used for the isolates and the bases in the background


### INPUT FILE FORMAT ###

This is a comma separated CSV file with the following columns
 - type: either I for isolate file or B for background file
   * Minimum of 2 I files if no B file
   * Max 1 B file with 1 or more I files
 - sampleName (optional): custom name for the different input files
 - genomeSize (optoinal): The size of each genome in bp (e.g. 3.7e6)
    if not set or missing values, defaults to value of argument -d.
	Ths parameter is ignored for background files (B) and can be blank
	
 DEPENDING ON PREFERENCE EITHER
  - relativeAbundance: RA of the file in the final metagenome (0-1).
     The sum of all must be 1.0 if only isolates 
     The sum must be < 1 when there is a background (RA is calculated)
  OR
  - coverage: The times a genome should be covered
  NOTE: background files (B) can have empty values 

 DEPENDING ON PREFERENCE EITHER
 - readFile: full path to the first read file (fastq.gz format)
 - readFile2: full path to the second read file (fastq.gz format)
    Leave empty in case of 1 data file
  OR
 - getFromSRA: fill in the SRR (leave readFile/readFile2 blank)
    The file will be downloaded from SRA if not found in the 
	default download folder (location can be changed in settings.txt) 
	
 NOTE: any other columns will be ignored, but kept as meta-data

EXAMPLE CSV FILE 
```
type,sampleName,genomeSize,relativeAbundance,readFile,readFile2,getFromSRA
I,isolate_1,4.1e6,0.1,~/isolate1_1.fastq.gz,~/isolate1_2.fastq.gz,
I,isolate_2,,0.3,,,SRR3222075
B,background,,,~/metagenome.fastq.gz,,
```

isolate_1: genome size ~4.1e6, RA 10%, 2 local input files
isolate_2: Grab file from SRA, genome size to default, RA 30%
background: genome size and RA not required, 1 local input file

-- END SEQ2MGS.SH ---
