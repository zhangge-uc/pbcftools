# pbcftools

**Parallelized bcftools wrapper for high-throughput variant processing.**

`pbcftools` runs most `bcftools` commands faster by splitting the genome into
coordinate ranges, running an ordinary `bcftools` process on each one concurrently,
and reassembling the output. The command line is the `bcftools` command line: your
flags keep their meaning and are forwarded unchanged, and the assembled output holds
the same records, in the same order, as a serial run.

> **Where splitting is exact.** Region splitting is correct for commands that decide
> each record independently. It is *not* guaranteed where the result depends on
> neighbouring records across a range boundary — `norm` left-aligning an indel past a
> boundary, or `csq` needing haplotype context that spans ranges. Commands that need
> the whole file are detected and run unparallelized. Validate `call`, `convert` and
> `csq` against serial `bcftools` on your own data before relying on them.

## Why pbcftools?

`bcftools` is the standard tool for VCF/BCF manipulation, but it processes records on
a single core; its `--threads` option speeds up only compression, not the work. For
large call sets — tens of millions of variants, thousands of samples — that single
core sets the wall-clock time.

`pbcftools` uses an **embarrassingly parallel** strategy: no communication between
processes and no shared state, just independent `bcftools` runs on non-overlapping
regions.

## Installation

### Requirements

- **Perl** ≥ 5.16 (tested on 5.34–5.40). No Perl threads needed.
- **bcftools** ≥ 1.15 in `$PATH` (tested on 1.21–1.24). 1.15 is the floor because
  pbcftools uses `--regions-overlap`.
- **`Parallel::ForkManager`** — the one non-core Perl module.

Everything else pbcftools uses ships with Perl. If Perl reports `Can't locate
<Module>.pm in @INC`, you have a minimal Perl install rather than a pbcftools bug:
Fedora/RHEL split the core modules into separate packages, so install `perl-core`
instead of `perl-interpreter` alone.

### Install dependencies

```bash
# Fedora / RHEL / CentOS
sudo dnf install perl-core perl-Parallel-ForkManager bcftools

# Ubuntu / Debian / WSL2   (bgzip is in `tabix`, not `bcftools`)
sudo apt install libparallel-forkmanager-perl perl-modules bcftools tabix

# macOS
brew install bcftools && cpan Parallel::ForkManager
```

Check that it resolves:

```bash
perl -MParallel::ForkManager -e 'print "deps OK\n"' && bcftools --version | head -1
```

### Install pbcftools

```bash
git clone https://github.com/zhangge-uc/pbcftools.git
cd pbcftools
perl bin/pbcftools.pl --help
```

No compilation. The script finds its modules relative to `bin/`.

### Platform support

| Platform | Notes |
|---|---|
| Linux x86_64 | Fedora 40 (Xeon Gold 6248R, 96 cores); RHEL 9.8 (Xeon 6517P, 64 cores) |
| macOS (Apple Silicon) | macOS 26.4.1, M2 (8 cores); deps via Homebrew |
| WSL2 (Windows) | Ubuntu 26.04 LTS, Core i7-12700 (20 cores) |
| HPC — LSF | `--p_mode lsf`; validated on a production LSF cluster |
| HPC — Slurm | `--p_mode slurm`; validated on an NSF ACCESS Slurm cluster |

Validated on four machines with bcftools 1.21–1.24 and Perl 5.34–5.40. On every one
the self-contained suites passed — **22/22** command comparisons and **132/132**
failure-handling checks — and every real-data workload matched serial output at every
concurrency setting, as did **33 live comparisons** on each cluster backend. Only the
achievable speed varied.

## Quick Start

```bash
# Extract fields to text
perl bin/pbcftools.pl query -f '%CHROM\t%POS\t%REF\t%ALT\n' \
    input.vcf.gz -o output.tsv --p_jobs 8 --p_len 10MB

# Split multiallelic records
perl bin/pbcftools.pl norm -m -both \
    input.vcf.gz -o output.vcf.gz --p_jobs 16 --p_len 10MB

# Summary statistics
perl bin/pbcftools.pl stats input.vcf.gz -o stats.txt --p_jobs 8

# Merge many VCF files into one
perl bin/pbcftools.pl merge --force-samples \
    -l vcf_list.txt -o merged.vcf.gz -Oz --p_jobs 16
```

### Choosing `--p_jobs` and `--p_len`

How much you gain depends on how much computation each record carries.

- **Writing compressed VCF/BCF gains most.** Compression is itself substantial work
  and divides along with the records, whether or not the file has samples.
- **Among commands writing text**, those reading per-sample genotypes still carry real
  work per record. Extracting a few fields from a sites-only file carries almost none,
  and gains little however many workers you add.

| | **light** — text out, no samples | **heavy** — compressed out, or per-sample |
|---|---|---|
| example | `query -f '%POS\t%AF'` on a sites file | `view -s`, `norm -m`, `annotate -x`, `merge` |
| **`--p_len`** | **50–100 MB** | **1–10 MB** |
| **`--p_jobs`** | 8–16 (more rarely helps) | up to physical cores |
| expect | under 4× | 10–35× on a server |

Two rules cover most cases:

1. **Size ranges so each does at least ~10 seconds of work.** Every range costs about
   one second in process start-up and an index seek. If a parallel run is *slower*
   than serial, the ranges are too small — raise `--p_len` before adding jobs.
2. **Don't over-subscribe.** Speed peaks near the physical core count and then
   declines: a 100-file merge on the 20-core workstation reached 4.4× at 16 workers
   but fell to 3.4× at 32. On shared machines, leave headroom for others.

### Temporary space

Each range is written to a scratch directory before assembly, so pbcftools needs room
for roughly a second copy of the **output** — which for `query` and other text formats
can be many times the input size (a 1.2 GB VCF of 2,504 samples yields a ~64 GB TSV).

The default is `$TMPDIR`, else `/tmp`. **Many current systems mount `/tmp` as a
RAM-backed tmpfs sized at ~50% of RAM**, so a workstation may offer only a few GB.
Check with `df -h /tmp` and redirect if needed:

```bash
export TMPDIR=/path/with/space          # or, per run:
pbcftools query ... --p_dir /path/with/space
```

For cluster modes `--p_dir` is required and must be on a filesystem visible from both
the submit host and the compute nodes.

> pbcftools warns below **2× the input size**. That suits VCF-to-VCF commands but
> understates text output badly — treat it as a floor, not an estimate.

## Supported Commands

**Region-parallel** — split into ranges, run concurrently, concatenate. Speedups are
measured on the 96-core server (see [Benchmark Results](#benchmark-results)):

| Command | Description | @16 | @32 |
|---|---|---:|---:|
| `view` | Subset samples, filter by PASS or expression | 7.2–11.5× | 13.7–21.1× |
| `norm` | Normalize indels, split/join multiallelic | 8.7× | 15.8× |
| `annotate` | Add or remove annotations | 7.2× | 13.7× |
| `filter` | Apply filter expressions | 5.9× | 10.8× |
| `query` | Extract fields to text | 2.7–9.6× | 3.7–12.2× |
| `call`, `convert`, `csq` | Routed but not yet verified — validate before relying on them | — | — |

**Aggregate** — per-range statistics combined with `plot-vcfstats -m`:

| Command | Description | @16 | @32 |
|---|---|---:|---:|
| `stats` | Variant statistics (genotypes / sites) | 7.6× / 4.5× | 12.8× / 8.2× |

`stats` on a small input can be *slower* than serial — the splitting cost is not
repaid. Parallelize it only for large call sets.

**Multi-input** — every input file is passed to each range:

| Command | Description | Measured |
|---|---|---|
| `merge` | Merge multiple VCF/BCF files (`-l`/`--file-list`, or positional) | **19.2×** on the 96-core server; **14.8×** on an LSF cluster |

Merging carries enough work per record that range size barely matters — varying
`--p_len` twenty-five-fold changed the result by under 4% — so the default is fine and
`--p_jobs` is the knob that counts.

**Chromosome-level** — one worker per contig, never sub-divided, because sequential
state carries along a sequence:

| Command | Description |
|---|---|
| `roh` | Runs of homozygosity |

`norm`, `filter`, `call`, `csq` and `convert` also enter this mode for certain
options. A user-supplied `-r` is honoured and treated as one indivisible unit;
`--p_len` is deliberately ignored so a region is never cut mid-run.

**Passed through to bcftools** — `isec`, `cnv`, `sort`, `index`, `concat`,
`reheader`, `head`, `consensus`, `gtcheck`, `polysomy`, `mpileup`, `query -l`, and the
plugins `+setGT`, `+fill-from-fasta`, `+missing2ref`, `+split`, `+scatter`. Most need
whole-file structure or global order, so they cannot be region-split; `mpileup` is
divisible in principle but reads BAM/CRAM rather than VCF, so it is left for a later
release. pbcftools runs all of these directly and the output is identical to
`bcftools`; only the speed-up is absent.

An unrecognized *command* or a plugin outside the names above is **refused**, not
passed through — pbcftools will not guess at a splitting strategy it has not verified.
For a plugin it does not know, call `bcftools` directly.

### When pbcftools parallelizes

Both must hold:

1. **The input is region-seekable** — every input file exists and is **indexed**
   (`.csi`/`.tbi`). Region extraction needs an index.
2. **The command has a defined split-and-merge strategy** — one of the modes above.

Anything else is a transparent passthrough: no input, an unindexed or plain-text
input, streamed stdin, or a whole-file command. This makes pbcftools a safe drop-in —
it accelerates what it can and otherwise behaves exactly like `bcftools`.

## Usage

All `bcftools` flags pass through. pbcftools adds:

```
Core options:
  --p_mode <local|lsf|slurm>  Backend (default: local)
  --p_jobs <int>        Parallel workers. Local default: 80% of logical cores,
                        capped at the number of ranges. Required for lsf/slurm.
  --p_len  <str>        Range size (default: 10MB; e.g. 5MB, 1e6)
  --p_dir  <dir>        Scratch directory (default: system tmpdir)
  --p_pre  <str>        Job-name / scratch prefix (default: pbcf)
  --p_ref  <37|38|hg19|hg38>  Built-in human chromosome sizes, for files
                        lacking contig headers
  --p_fai  <ref.fa.fai> Fasta index for contig sizes — any organism
  --p_index <0|1>       Index the assembled output (default: 1, CSI). A
                        user-supplied -W/--write-index overrides this and
                        selects the format.
  --p_yes               Skip confirmation prompts (for scripting)

Cluster options (LSF / Slurm):
  --p_wal     <str>     Wall time per job (default: 1hr; e.g. 2h, 90m, 1:30)
  --p_mem     <str>     Memory per job (default: 8GB)
  --p_cpu     <int>     CPUs per job (default: 1)
  --p_int     <int>     Poll interval, seconds (default: 10)
  --p_try     <int>     Max retries per failed job (default: 3)
  --p_mem_inc <int>     % memory increase per retry (default: 50)
  --p_wal_inc <int>     % wall-time increase per retry (default: 50)
  --p_queue   <str>     Queue / partition
  --p_account <str>     Project / account
```

`pbcftools --help` lists these too, and is the authoritative reference.

### Examples

```bash
# Region-restricted query
perl bin/pbcftools.pl query -f '%CHROM\t%POS\n' -r 1:1-50000000 \
    input.vcf.gz -o output.tsv --p_jobs 8 --p_len 5MB

# Filter by expression, auto-detect cores
perl bin/pbcftools.pl filter -i 'INFO/AF>0.05' \
    input.vcf.gz -o filtered.vcf.gz --p_len 10MB

# Input without contig headers: supply sizes
perl bin/pbcftools.pl stats input.vcf.gz -o stats.txt --p_jobs 16 --p_ref 37

# LSF cluster. --p_dir is REQUIRED and must be visible from the compute nodes.
perl bin/pbcftools.pl view -S samples.txt input.vcf.gz -o output.vcf.gz \
    --p_mode lsf --p_dir /scratch/$USER/pbcf.run1 \
    --p_jobs 200 --p_len 5MB --p_wal 2h --p_mem 16GB
```

### Cluster notes

- Run from an interactive session (`bsub -Is`, `salloc`) rather than a login node.
- Failed jobs retry automatically with 1.5× wall time and memory.
- Ctrl-C stops the submission wave and cancels tracked jobs. If cancellation cannot
  be confirmed, pbcftools warns about possible strays — inspect jobs by the reported
  `--p_pre` prefix (default `pbcf`) before rerunning.
- `--p_jobs` caps *simultaneous* jobs, not the total number of ranges.
- Queue waiting is included in cluster timings, so cluster runs pay off when each job
  is substantially longer than a typical wait. Use larger `--p_len` than you would
  locally; for work of a few minutes, local cores are usually the better choice.

## Testing

```bash
# Self-contained suites — build their own data, no downloads needed
bash tests/run_tests_safety.sh          # correctness and failure-handling checks
bash tests/run_tests.sh                 # 22 parallel-vs-serial comparisons
```

`run_tests_safety.sh` reports **131 passed, 0 failed, 1 skipped**. The skip is
expected: that check drives the cluster controller through a mock scheduler, which is
a development harness and is not distributed.

Both exit non-zero on any failure. `run_all.sh` and `run_tests_hpc.sh` need **bash ≥ 4**
(macOS ships 3.2: `brew install bash`). `run_all.sh` re-execs itself under a newer bash
if it finds one; `run_tests_hpc.sh` asks you to run it under one.

Benchmarking against real data needs 1000 Genomes Phase 3 files (note contigs are
**not** `chr`-prefixed):

```bash
mkdir -p tests/data && cd tests/data     # where the harness looks by default
# Sites-only, genome-wide (1.9 GB, 84.8M variants)
wget https://ftp.1000genomes.ebi.ac.uk/vol1/ftp/release/20130502/ALL.wgs.phase3_shapeit2_mvncall_integrated_v5b.20130502.sites.vcf.gz{,.tbi}
# Chr1 genotypes (1.2 GB, 6.5M variants, 2504 samples)
wget https://ftp.1000genomes.ebi.ac.uk/vol1/ftp/release/20130502/ALL.chr1.phase3_shapeit2_mvncall_integrated_v5a.20130502.genotypes.vcf.gz{,.tbi}
bcftools index ALL.wgs.*.sites.vcf.gz
bcftools index ALL.chr1.*.genotypes.vcf.gz
```

Or point at copies you already have with `--sites FILE` / `--geno FILE`.

Then:

```bash
bash tests/run_tests.sh --benchmark --cpus 4,8,16     # ~30 min
bash tests/make_merge_fixture.sh                      # 100 files x 10 samples (~3.5 GB)
bash tests/make_merge_fixture.sh --region 1 --force   # whole chr1 (~17 GB) — what the
                                                      # published merge numbers used
bash tests/run_tests_merge.sh mylabel --cpus 16       # merge scaling
bash tests/run_tests_hpc.sh --benchmark --jobs 100    # LSF/Slurm backend
bash tests/run_all.sh mylabel                         # all local suites, in order
```

Pass a platform label so each suite writes its own `tests/*_report_<label>.md` rather
than overwriting a shared name — useful when comparing machines. The benchmark and
merge reports also record the host, CPU, RAM and OS.

## Benchmark Results

1000 Genomes Phase 3 data: a whole-genome sites-only file (84.8M variants) and
chromosome 1 genotypes for 2,504 samples (6.5M variants), using 10 Mb ranges for
sites-only work and 1 Mb for genotypes. Every comparison below produced records
identical to serial `bcftools`.

96-core server (Xeon Gold 6248R, Fedora 40, bcftools 1.22):

| Operation | Output | Serial (s) | @4 | @8 | @16 | @32 | @64 |
|---|---|---:|---:|---:|---:|---:|---:|
| `view -s` subset three samples | VCF | 528.6 | 3.04× | 5.93× | 11.48× | 21.14× | **35.35×** |
| `norm -m -both` split multiallelics | VCF | 353.6 | 2.30× | 4.50× | 8.74× | 15.82× | **26.55×** |
| `view -f PASS` | VCF | 287.1 | 1.95× | 3.80× | 7.27× | 14.09× | 23.31× |
| `view -i 'TYPE="snp"'` | VCF | 277.1 | 1.89× | 3.73× | 7.23× | 13.72× | 22.72× |
| `annotate -x INFO/AF` | VCF | 277.8 | 1.90× | 3.73× | 7.24× | 13.69× | 22.71× |
| `filter -i 'INFO/AF>0.05 && …'` | VCF | 133.3 | 1.61× | 3.14× | 5.94× | 10.75× | 18.05× |
| `stats` (genotypes) | text | 149.6 | 2.24× | 4.17× | 7.58× | 12.77× | 17.12× |
| `query` genotypes with REF/ALT | text | 950.9 | 3.24× | 5.70× | 8.75× | 12.13× | 13.95× |
| `stats` (sites) | text | 102.0 | 1.24× | 2.40× | 4.54× | 8.23× | 13.79× |
| `query` genotypes | text | 941.2 | 3.22× | 5.77× | 9.64× | 12.20× | 13.71× |
| `query` sites | text | 104.7 | 1.06× | 1.79× | 2.72× | 3.69× | 4.47× |

Smaller machines reach lower ceilings, set by their core count: the 20-core
Windows/WSL2 workstation peaked near 7×, the 8-core Apple M2 laptop near 5×. Both
flatten once the number of concurrent ranges approaches the core count.

**Merging.** 100 VCF files of 10 samples each, across chromosome 1, producing
**6,468,094 records identical to serial** in every run:

| Machine | Serial | Best | At |
|---|---:|---:|---|
| 96-core Linux server | 2868.9 s | **19.2×** | 64 workers |
| 20-core WSL2 workstation | 1711.8 s | 4.4× | 16 workers |
| 8-core Apple M2 laptop | 1256.5 s | 2.4× | 16 workers |
| LSF cluster | 2117.6 s | **14.8×** | 256 jobs |

A cluster helps here precisely because it offers far more concurrent jobs than one
machine has cores.

**How to read these numbers.** All timings are single runs, serial first and then
parallel, without clearing the file-system cache, so they are somewhat optimistic and
describe the shape of the scaling rather than a guarantee for other storage.
Automatic indexing of the assembled output was disabled (`--p_index 0`), because
serial `bcftools` does not write an index unless asked; with it enabled, expect a
fixed single-core cost on top.

## Limitations

**Some commands are not parallelized.** `sort`, `concat`, `index`, `reheader`, `head`
and `consensus` need the whole file at once. `isec` and `cnv` are also run serially,
by choice: parallelizing them meant reproducing details of how `bcftools` reads their
options, which is fragile. In every case the output is identical to `bcftools`; only
the speed-up is absent.

**Plugins run serially.** `+fill-tags` is accepted and correct, but pbcftools works
out how many arguments an option takes by reading the command's own help, and a
plugin's help lists only the plugin's own options. Rather than guess, it declines to
divide the work.

**The gain depends on the work per record.** Operations writing compressed VCF, or
computing something per sample, gain most. Extracting a few text fields from a
sites-only file gains little, and on files that take only seconds serially the cost of
splitting is not repaid at all.

**Range size matters in both directions.** Ranges must be big enough that real work
outweighs process start-up, and numerous enough to keep your cores busy — dividing a
whole genome into 100 Mb ranges gives only ~31 pieces, which cannot fill 64 cores.
pbcftools prints both the range size and the piece count so a mismatch is visible.

**Scratch space.** Assembly needs room for roughly a second copy of the output, and
`/tmp` is a RAM-backed tmpfs on many current systems. See [Temporary
space](#temporary-space).

**One argument is not passed through untouched.** `bcftools norm -Na` is rewritten as
`-N a`, which changes its meaning. On bcftools 1.23 and earlier `-N` is a flag, so
`-Na` means `-N -a` and runs fine serially — but the rewritten form is rejected, so
this is one spelling that works under `bcftools` and fails under `pbcftools`. On 1.24
`-N` takes an optional argument and both forms fail. Either way pbcftools stops rather
than producing wrong output. Write `-N -a` to avoid it; a fix is scheduled.

**Tested range.** Linux, macOS and WSL2, with `bcftools` 1.21–1.24 and Perl 5.34–5.40.
Older `bcftools` back to 1.15 should work but has not been exercised.

Please report anything you hit through GitHub Issues.

## Architecture

```
bin/pbcftools.pl              # Entry point: parsing, validation, splitting, dispatch, assembly
lib/PBCFTools/
    Helpers.pm                # Display, conversion, user interaction
    ArgParser.pm              # Command-aware bcftools argv scanner (input/list discovery)
    Backend/
        Cluster.pm            # Shared submit/poll/escalate controller (LSF + Slurm)
        Local.pm              # Parallel::ForkManager — local multicore execution
        LSF.pm                # bsub submission, bulk bjobs polling, auto-escalation
        Slurm.pm              # sbatch submission, squeue/sacct polling
tests/
    run_tests.sh              # Local-backend harness: quick, benchmark, full
    run_tests_safety.sh       # Self-contained correctness and failure-handling suite
    run_tests_merge.sh        # Multi-input merge scaling
    run_tests_hpc.sh          # LSF/Slurm-backend harness (run separately, on a cluster)
    run_all.sh                # Runs the local suites in order (not the cluster one)
    make_merge_fixture.sh     # Builds the merge fixture from 1000 Genomes chr1
    common.sh                 # Shared option parsing and output comparison
    tests.cmd                 # The workload manifest every harness reads
```

## How It Works

1. **Parse** — intercept `-o` and the `--p_*` flags; pass everything else through.
2. **Validate** — run `bcftools` against a dummy region to catch argument errors
   immediately, before any work is dispatched.
3. **Split** — build `[chr, start, end]` ranges from the header contigs (or `--p_ref`
   / `--p_fai`), sub-splitting anything over 1.5× the range size.
4. **Execute** — dispatch to the backend: `fork()` locally, `bsub`/`sbatch` on a
   cluster.
5. **Assemble** — VCF/BCF via `bcftools concat` (`--naive` block-copy for BGZF); text
   by concatenation; `stats` via `plot-vcfstats -m`. A `##pbcftools_command`
   provenance line is injected into the first chunk's header.
6. **Index** — auto-index VCF/BCF output.

## Author

G. Zhang (zhangge-uc)

## License

MIT
