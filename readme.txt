########## METAMIXER ##########
##############################
   Developed by PJ Van Camp

--- SETUP.SH ---
Run the setup.sh script to verify all dependencies and to test the pipeline.

Arguments [h|t]
 -h Read the help documentation
 -t Run pipeline tests with dummy data (will take some time)

The following software needs to be installed:
- SQLite3 
  * Precompiled 32-bit version: https://www.sqlite.org/download.html
  * Precompiled 64-bit version: https://github.com/boramalper/sqlite3-x64/releases
- R version 4.0+
  * Packages: RSQLite, tidyverse (with dplyr 1.0+)
  * Precompiled versions: https://www.r-project.org/ 
- bbmap (reformat.sh)
  * https://jgi.doe.gov/data-and-tools/bbtools/bb-tools-user-guide/installation-guide/
- sratoolkit (fasterq-dump)
  * https://github.com/ncbi/sra-tools

Optional software
- pigz
  * If installed, zipping files will be faster on multi-core machines compared to gzip
   
IMPORTANT: Update the paths to all dependencies in the 'settings.txt' file 
 if they are not in the default PATH

-- END SETUP.SH ---


--- METAMIXER.SH ---
Mix multiple isolate WGS files together to create artificial metagenomes 

Arguments [h|i|o|r|m|t|f|v]
 -h Read the help documentation
 -i The input file (.csv) containing all samples to be mixed
 -o The location to save the output file. Filename should end with a fastq.gz extension
 -r (optional) The max number of reads the mixed file should contain. 
     By default, the number of reads in the background file is chosen.
     If no background file is present, the limit is the sum of 
	 the fractions needed from each isolate file.
 -m (optional) TRUE or FALSE. 
     Generate a meta-data JSON file in the same folder as the output file.
     Default can be changed in the settings.txt file
 -t (optional) The location of the temp folder (files removed once completed). 
     Default can be changed in the settings file
 -f (optional) If set, force overwriting an existing output file
 -v (optional) TRUE or FALSE. Progress is posted to stdout when TRUE.
     Default can be changed in the settings.txt file


Input file details --
This is a .csv file with the following columns
 - type: either I for isolate file or B for background file
   * Minimum of 2 I files if no B file
   * Max 1 B file and 1 or more I files
 - sampleName (optional): custom name for the different input files
 - relativeAbundance: relative abundance of the file in the final metagenome.
    The sum of all must be 1.0
 - readFile: full path to the first read file (fastq.gz format)
 - readFile2: full path to the second read file (fastq.gz format)
    Leave empty in case of 1 interleaved data file
 - getFromSRA: the file is downloaded from SRA (leave readFile(2) blank)
 - Any other columns will be ignored, but put in the meta-data JSON file if generated

-- END METAMIXER.SH ---
