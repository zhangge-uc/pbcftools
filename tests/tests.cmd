#=============================================================================
# tests.cmd — the pbcftools test and benchmark command list
#
# Each line beginning with `bcftools` is one test. The harness runs it TWICE:
#   serial    the line exactly as written
#   parallel  with `bcftools` replaced by pbcftools, plus the parallel options
# and then compares the two outputs. A test passes when they match.
#
# Lines are shell, evaluated with these variables set for you:
#
#   $SITES      1000G whole-genome sites-only VCF   (no samples, ~84.8M variants)
#   $GENO       1000G chr1 genotypes VCF            (2504 samples, ~6.5M variants)
#   $R_SITES    expands to `-r <region>` for $SITES, or nothing
#   $R_GENO     expands to `-r <region>` for $GENO,  or nothing
#   $REF        reference FASTA, if one was configured
#   $OUT        output path prefix for THIS test — append your own extension
#   $OUTDIR     a directory you may create, for commands that write a tree
#
# $SITES and $GENO have very different shapes, so they take SEPARATE regions:
# `--region_sites` and `--region_geno` (or `--region` to set both).
#
# Tiers are the `## name` headings. Run a subset with `--tier interval,advanced`.
# Add your own commands under any tier — they are picked up automatically.
#=============================================================================


## interval
# Commands that split cleanly by genomic interval. The bulk of real usage.

# sites-only query to a tab file
bcftools query -f '%CHROM\t%POS\t%REF\t%ALT\t%INFO/AF\n' $R_SITES $SITES -o $OUT.tsv

# genotype query, one column per sample
bcftools query -f '%CHROM\t%POS[\t%GT]\n' $R_GENO $GENO -o $OUT.tsv

# view to compressed VCF
bcftools view $R_SITES $SITES -Oz -o $OUT.vcf.gz

# view to BCF
bcftools view $R_GENO $GENO -Ob -o $OUT.bcf

# view to uncompressed VCF (a different assembly path from BGZF)
bcftools view $R_SITES $SITES -Ov -o $OUT.vcf

# filter on an INFO expression
bcftools filter -i 'AF>0.05' $R_SITES $SITES -Oz -o $OUT.vcf.gz

# split multiallelics — the headline CPU-bound operation
bcftools norm -m -both $R_SITES $SITES -Oz -o $OUT.vcf.gz

# annotate: set the ID column from CHROM/POS
bcftools annotate --set-id '%CHROM\_%POS' $R_SITES $SITES -Oz -o $OUT.vcf.gz


## chromosome
# Sequential algorithms: split per contig only, never within one.

# runs of homozygosity (needs -G because the fixtures carry no PL)
bcftools roh -G30 --AF-dflt 0.4 $R_GENO $GENO -o $OUT.txt

# NOTE: `cnv` is deliberately NOT listed here. It runs unparallelized (passthrough),
# so a serial-vs-parallel comparison has nothing to compare. That it passes through,
# and that its output is unchanged, is covered by run_tests_safety.sh instead.


## aggregate
# Per-region results that are merged rather than concatenated.

# summary statistics
bcftools stats $R_SITES $SITES > $OUT.stats


## multi
# Multi-input commands. merge is the only one pbcftools parallelises: every input
# is passed to each region chunk, then the chunks are concatenated.

# merge two overlapping inputs (same samples, so --force-samples)
bcftools merge --force-samples $R_GENO $GENO $SUBSET -Oz -o $OUT.vcf.gz


## passthrough
# Cases pbcftools must NOT parallelise. The output must still equal serial.

# header only
bcftools view -h $SITES -o $OUT.vcf

# whole-file sort has no valid region split
bcftools sort $SUBSET -Oz -o $OUT.vcf.gz

# stream to stdout rather than a file
bcftools view -H $R_SITES $SITES -Ov -o $OUT.vcf

# NOTE: the LAST comment line before a command becomes its description, so keep
# any explanation above the one-line description.
# isec: sites list — runs serially, output must still equal serial
bcftools isec -n =2 $R_GENO $GENO $SUBSET -o $OUT.txt

# isec: write records from the first file — also serial
bcftools isec -n =2 -w 1 $R_GENO $GENO $SUBSET -Oz -o $OUT.vcf.gz


## advanced
# Argument spellings that have caused wrong output before. These matter MORE on a
# different platform, because option arity is read from `bcftools --help` at run
# time — a different bcftools version is exactly what could break them.

# bundled short options: -a -O b written as one token
bcftools view -aOb $R_GENO $GENO -o $OUT.bcf

# bundled option with an attached region value
bcftools query -ur1:1000000-1200000 -f '%CHROM\t%POS\n' $GENO -o $OUT.tsv

# unambiguous long-option abbreviation
bcftools view --min-al 2 $R_SITES $SITES -Oz -o $OUT.vcf.gz

# brace contig spelling names ONE contig, not two
bcftools query -r '1:1000000-1100000,{1}:1050000-1150000' -f '%CHROM\t%POS\n' $GENO -o $OUT.tsv

# attached long-option value
bcftools view --output-type=z $R_SITES $SITES -o $OUT.vcf.gz

# targets rather than regions (streams instead of index-jumping)
bcftools view -t 1:1000000-1200000 $GENO -Oz -o $OUT.vcf.gz


## benchmark
# Timed serial vs parallel, correctness still checked at every level. This mirrors
# the workload set the pre-manifest suite measured, so figures stay comparable with
# the earlier cross-platform reports: two datasets (sites-only and genotypes), and a
# spread of I/O-bound, CPU-bound and filter-bound operations.
#
# Cost: each workload times the serial side ONCE and then each --jobs level, so N
# workloads cost N x (1 + levels) runs. Trim with --tier or by commenting lines out
# if you only need part of the picture.

# sites-only query to a tab file — I/O and parsing bound, no samples
bcftools query -f '%CHROM\t%POS\t%REF\t%ALT\t%INFO/AF\n' $R_SITES $SITES -o $OUT.tsv

# genotype query, one column per sample — the widest rows in the set
bcftools query -f '%CHROM\t%POS[\t%GT]\n' $R_GENO $GENO -o $OUT.tsv

# genotype query including REF/ALT — more per-record formatting work
bcftools query -f '%CHROM\t%POS\t%REF\t%ALT[\t%GT]\n' $R_GENO $GENO -o $OUT.tsv

# subset three samples — exercises the per-sample path and BGZF rewriting
bcftools view -s $SAMPLES $R_GENO $GENO -Oz -o $OUT.vcf.gz

# keep PASS records only — cheap predicate, dominated by I/O
bcftools view -f PASS $R_SITES $SITES -Oz -o $OUT.vcf.gz

# an INFO range expression — filter-bound
bcftools filter -i 'INFO/AF>0.05 && INFO/AF<0.95' $R_SITES $SITES -Oz -o $OUT.vcf.gz

# SNPs only, via a type expression
bcftools view -i 'TYPE="snp"' $R_SITES $SITES -Oz -o $OUT.vcf.gz

# strip an INFO field — rewrites every record
bcftools annotate -x INFO/AF $R_SITES $SITES -Oz -o $OUT.vcf.gz

# split multiallelics — the headline CPU-bound operation
bcftools norm -m -both $R_SITES $SITES -Oz -o $OUT.vcf.gz

# summary statistics over the sites file — aggregate mode, merged per region
bcftools stats $R_SITES $SITES > $OUT.stats

# summary statistics over the genotypes file — the heavier stats case
bcftools stats $R_GENO $GENO > $OUT.stats
