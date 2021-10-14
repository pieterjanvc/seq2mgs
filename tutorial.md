# SEQ2MGS

SEQ2MGS is a simple tool for generating artificial metagenomics data by mixing together existing sequencing files 

## Setup

*NOTE: This pipeline runs on the Linux operating system*

### Install all dependencies

REQUIRED

- SQLite3 
  - Precompiled 32-bit: https://www.sqlite.org/download.html
  - Precompiled 64-bit: https://github.com/boramalper/sqlite3-x64/releases
- R version 4.0+
  - Packages: RSQLite, tidyverse (dplyr 1.0+), jsonlite, httr
  - Precompiled versions: https://www.r-project.org/ 
    OR: https://docs.rstudio.com/resources/install-r/
- bbmap
  - https://jgi.doe.gov/data-and-tools/bbtools/bb-tools-user-guide/installation-guide/
- sratoolkit
  - https://github.com/ncbi/sra-tools
  - !! Make sure to configure the tool before using it!!
    https://github.com/ncbi/sra-tools/wiki/03.-Quick-Toolkit-Configuration
    This needs to be done for every user who runs it (including root)
  - The default download folder is SRAdownloads/ in the SEQ2MGS folder
    This can be changed in the settings file

OPTIONAL

- pigz
  - If installed, faster zipping with multi-cores
  
**IMPORTANT**: Make sure all dependencies are in the $PATH variable. Read [this blog](https://opensource.com/article/17/6/set-path-linux) for help.

### Install the SEQ2MGS repository

Get the latest release from the [SEQ2MGS repository](https://github.com/pieterjanvc/seq2mgs/releases) on GitHub. 
Unpack it on your local machine and make sure the the folder and subfolders 
have read / write / execute permissions.

### Verify installation

Run the setup.sh script in the SEQ2MGS root folder to verify that all 
dependencies have been installed correctly and can be found by the pipeline.
```
# Check dependencies ...
setup.sh

# ... OR check dependencies + run small test
setup.sh -t

```

## Creating input files

SEQ2MGS requires a csv input file that details the files to be mixed and its metadata. 

### Input data columns
- **Type**: All isolates are labeled 'I', when a background is specified it is labeled 'B'. There can only be one background file, and when none is present, a minimum of 2 isolate files are needed.
- **sampleName**: (optional) Name given to the file for easier identification in the report 
- **genomeSize**: (optional) The estimated genome size of the isolate bacterium. If not set, a default value will be used
- **relativeAbundance**: The relative abundance (RA) of the isolate in the resulting mix. 
- **coverage**: The estimated coverage of an isolate. The genomeSize value is used to provide better results by adjusting for genome size
- **readFile**: The full path to the sequencing data (fastq.gz format)
- **readFile2**: (optional) The full path to the second file of sequencing data (fastq.gz format) in case of split reads
- **getFromSRA**: If the SRA toolkit is installed, a sequencing file can be automatically downloaded from SRA. In this case, readFile and readFile2 are kept blank (see details in SRA download section below)

### Examples of csv input files

#### Mixing 3 isolates together with specific relative abundance

type | genomeSize | relativeAbundance | readFile | readFile2 | getFromSRA
-----|------------|-------------------|------------------|-----------|-----------
I | 3.1e6 | 0.1 | /path/isolate1_1.fastq.gz | /path/isolate1_2.fastq.gz |
I | 4.2e6 | 0.6 | /path/isolate2.fastq.gz | |
I | 3.94e6 | 0.3 | | | SRR3222484

- When mixing isolates only, the realtiveAbundance column must have a value for each file and 0 > RA > 1. The sum of all RA *must* be 1
- Since RA is chosen as the option for mixing, the coverage column should not be present
- Although not strictly required, the genomeSize is important to make sure correct coverage estimates are reached


#### Mixing 2 isolates together with specific coverage

type | sampleName | genomeSize | coverage | readFile | readFile2 | getFromSRA
-----|------------|------------|-------------------|------------------|-----------|-----------
I | A. baumannii | 3.94e6 | 40 | | | SRR3222484
I | Bacterium X | 2.7e6 | 10 | /path/bacteriumx.fastq.gz | |

- When mixing isolates only, the coverage column must have a value for each file
- Since coverage is chosen as the option for mixing, the relativeAbundance column cannot not be present
- Although not strictly required, the genomeSize is important to make sure correct coverage estimates are reached


#### Mixing 1 isolate into a background

type | sampleName | genomeSize | coverage | getFromSRA
-----|------------|------------|-------------------|------------------
I | A. baumannii | 3.94e6 | 20 | SRR3222484
B | Gut metagenome | | | SRR5091474

- When using a background file, the coverage is left blank for the background (and will be ignored otherwise)
- If all files come from SRA, the readFile / readFile2 column can be omitted


#### Mixing 2 isolates into a background

type | genomeSize | relativeAbundance | readFile | readFile2 | getFromSRA
-----|------------|-------------------|------------------|-----------|-----------
I | 3.1e6 | 0.1 | /path/isolate1_1.fastq.gz | /path/isolate1_2.fastq.gz |
I | 4.3e6 | 0.05 | /path/isolate2.fastq.gz | |
B | | | | | SRR5091474

- The sum of the RA does not need to be 1 for the isolates, as they are calculated in reference to the background file
- Genome size and relative can be left blank for a background file (and will be ignored otherwise)


## Running SEQ2MGS

Once the input files are created, the seq2mgs.sh script can be run with just a few parameters

```
seq2mgs.sh -i <inputFile>.csv -o <outputFile>.fastq.gz
```
* -i: the path to the .csv input file
* -o: the path to the .fastq.gz file that will contain the result

Along with the fastq.gz output file, a metadata file with the same name (but .json extension) is generated listing some of the properties of the mixed data. 
If the '-m false' flag is set, this file will not be generated. 

For additional options and filters, see the help file
```
seq2mgs.sh -h
```


## Changing default settings

The settings.txt file in the SEQ2MGS root folder contains some default parameters that can be changed

* **sraDownloadFolder**: The path to the sequencing data downloaded from SRA. 
Once data is in this folder, it will not be downloaded again unless the 
folder / data is moved. The initial value is the SRAdownloads folder in the root 
of SEQ2MGS
* **seq2mgsDefaultGenomeSize**: The default genome size to use when the option 
in the input file is blank (e.g. 3.7e6). Using a default genome size will result 
in less accurate coverage / relative abundance
* **seq2mgsMaxResample**: When there are not enough reads in a file, SEQ2MGS 
will resample until the desired number is reached. This value is a safeguard to 
prevent the pipeline from copying a file over and over as is reduces the quality 
of the output (duplicate reads contain no new information) and can take a very 
long time  
* **seq2mgsMetaData**: TRUE / FALSE. Generate the json metadata file when 
running the pipeline
* **seq2mgsVerbose**: TRUE / FALSE. When true, progress is written to stdout
* **seq2mgsTemp**: The temp folder to store intermediate files used when mixing. 
A subfolder is created for each run and is removed after completion


## The backend database

A SQLite database located in dataAndScripts/seq2mgs.db of the SEQ2MGS folder 
keeps track of logs, errors, file and meta data. 

This database is not needed for basic use of the tool, but can be useful when 
trying to evaluate specific runs of the tool, the data used, or some log and
output parameters. It also keeps track of read counts in sequencing files 
that have been used as input so speed up the mixing if used again.

The detailed database schema can be found in the 
dataAndScripts/createSeq2mgsDB.sql file if needed.

---


