########## METAMIXER ##########
##############################
   Developed by PJ Van Camp
     vancampn@mail.uc.edu

--- SETUP.SH ---
Run the setup.sh script to verify all dependencies and to test the pipeline.
THe first time a database will be created in the dataAndScripts folder

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
    OR: https://docs.rstudio.com/resources/install-r/
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
 
 DEPENDING ON PREFERENCE EITHER
	 - relativeAbundance: relative abundance of the file in the final metagenome (0-1).
		The sum of all must be 1.0 if only isolates 
		The sum must be < 1 when there is a background (its RA will be calculated)
	OR
	 - coverage: The times a genome should be covered

 - genomeSize: The size of each genome in basepairs (e.g. 3.7e6)
    if not set or missing values, defaults to value of argument -d
 - readFile: full path to the first read file (fastq.gz format)
 - readFile2: full path to the second read file (fastq.gz format)
    Leave empty in case of 1 interleaved data file
 - getFromSRA: fill in the SRR (leave readFile/readFile2 blank)
    The file will be downloaded from SRA 
 - Any other columns will be ignored, but put in the meta-data JSON file if generated

-- END METAMIXER.SH ---
