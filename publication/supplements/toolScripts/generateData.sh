#!/bin/bash
#Make sure to set the paths to all the different tools of not in $PATH

#Generate CAMISIM data
python2.7 metagenomesimulation.py camisim_config.ini

#Generate the corresponding SEQ2MGS data
seq2mgs.sh -i seq2mgs_ASF_csv \
	-o metaMixer_ASF_250Mbp.fastq.gz \
	-u 25e7

#Generate Grinder data
grinder -reference_file grinder_ASF.fna \
	-total_reads 166666 \
	-read_dist 150 normal 0 \
	-abundance_file grinder_relAb.txt \
	-mutation_dist poly4 3e-3 3.3e-8 \
	-fq 1 \
	-qual_levels 30 10 \
	-base_name grinder_ASF \
	-output_dir ./

#Generate the corresponding SEQ2MGS data
seq2mgs.sh -i seq2mgs_ASF_csv \
	-o metaMixer_ASF_25Mbp.fastq.gz \
	-u 25e6
