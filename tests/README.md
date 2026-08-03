# pbcftools tests

Every command in `tests.cmd` is run **twice** — once with `bcftools`, once with
`pbcftools` — and the two outputs are compared. A test passes when they agree.

## Quick start (no download needed)

```bash
bash tests/run_tests.sh                 # correctness, synthetic data, ~1 minute
bash tests/run_tests.sh --list          # show what would run
bash tests/run_tests.sh --tier interval,advanced
```

Correctness needs **only `bcftools` and `bgzip` on your PATH** (`bgzip` builds the
fixtures; on Debian/Ubuntu it is in the `tabix` package). The script builds its own
small fixtures, so a fresh install can be verified immediately. Only the benchmark
needs real data, because a speedup measured on a toy file means nothing.

## The scripts

| script | what it does |
|---|---|
| `run_tests.sh` | runs `tests.cmd` locally; `--benchmark` switches to the timing tier |
| `run_tests_safety.sh` | self-contained correctness and failure-handling checks |
| `run_tests_hpc.sh` | the same idea through LSF or Slurm (`--p_mode lsf\|slurm`) |
| `run_tests_merge.sh` | many-input `merge`, which needs its own fixture |
| `make_merge_fixture.sh` | builds that fixture from 1000 Genomes chr1 |
| `run_all.sh` | runs the local suites on one machine, writing a report per suite |
| `common.sh` | the shared comparison and the shared options — not run directly |

## Shared options

These mean the same thing in the local scripts, which all parse them through
`common.sh`. `run_tests_hpc.sh` keeps its own parser for the scheduler options and
accepts only the subset listed in its header:

```
--label NAME         name for the report file
--tier LIST          comma-separated tiers to run
--list               print the selected tests and exit
--jobs N[,N,...]     worker counts / concurrent jobs      (alias: --cpus)
--benchmark          run the benchmark tier INSTEAD of the correctness tiers
--keep               keep outputs for inspection
--sites FILE         1000G sites-only VCF                 (benchmark tier only)
--geno FILE          1000G chr1 genotypes VCF             (benchmark tier only)
--sites-region REG   benchmark region for the sites file
--geno-region REG    benchmark region for the genotypes file
--region REG         set both benchmark regions at once
--p_*                passed straight through to pbcftools
```

Two conventions worth knowing:

- **`--p_<name>` goes to pbcftools**, spelled exactly as pbcftools spells it.
  Everything else belongs to the harness.
- **`--jobs` never selects a backend.** `--p_mode local|lsf|slurm` does, alone.

## Adding your own tests

Append to `tests.cmd` under any tier. Nothing else needs changing:

```
## interval
# my own check: keep only PASS records
bcftools view -f PASS $R_SITES $SITES -Oz -o $OUT.vcf.gz
```

Write the command exactly as you would run it with `bcftools`. `$OUT` is a path
prefix the harness supplies — append your own extension. For `stats`, `roh` and
other commands that have no `-o` and write to stdout, use `> $OUT.ext`; the harness
converts that to `-o` for the pbcftools side.

## Benchmark data

The benchmark tier uses two 1000 Genomes Phase 3 files. Download them into
`tests/data/` (or point at them with `--sites` / `--geno`):

**Whole-genome sites-only** — ~1.9 GB, 84.8M variants, no samples:

```
https://ftp.1000genomes.ebi.ac.uk/vol1/ftp/release/20130502/\
ALL.wgs.phase3_shapeit2_mvncall_integrated_v5b.20130502.sites.vcf.gz
```

**chr1 genotypes** — ~1.2 GB, 6.5M variants, 2504 samples:

```
https://ftp.1000genomes.ebi.ac.uk/vol1/ftp/release/20130502/\
ALL.chr1.phase3_shapeit2_mvncall_integrated_v5a.20130502.genotypes.vcf.gz
```

Index both with `bcftools index` after downloading.

```bash
bash tests/run_tests.sh --benchmark --sites-region 1:1-50000000 \
                                    --geno-region  1:1-45000000
```

The two files take **separate** regions on purpose. Their densities differ by more
than an order of magnitude, so one region string applied to both means very
different amounts of work, and a region tuned for one is misleading for the other.
`--region` sets both, for when you genuinely want that.

## Two workload types, two sets of defaults

The benchmark manifest mixes commands that read a **sites-only** file with commands
that read **genotype** columns for 2504 samples. They differ by ~3 orders of magnitude
in work per record, so the harness gives them separate defaults:

| | sites-type | genotype-type |
|---|---|---|
| default region | **whole genome** | **`1`** (chr1) |
| chunk size | **10x** `--p_len` | `--p_len` as given |

A workload is classified from the manifest itself: a command naming `$GENO`/`$R_GENO`
is genotype-type, everything else is sites-type. The header and the report record both
chunk sizes, and each workload prints the one it used.

`--p_len` on the command line therefore sets the **genotype** chunk; sites workloads
get ten times that. Override the regions with `--sites-region` / `--geno-region`, or
both at once with `--region`.

This exists because the earlier cross-platform runs used `--p_len 1M` for both. Over
chr1 that is ~249 chunks, and for the sites file each chunk re-opened a 1.9 GB file
and index-seeked: parallel time came out inversely proportional to job count with a
constant product (~260 core-seconds at every level, on every machine from an M2 to a
96-core Xeon), i.e. the measurement was of fixed per-chunk cost, not of parallelism.

## Scratch space — `/tmp` is often far too small

**Give the benchmark ~150 GB of scratch, and do not assume `/tmp` has it.**

The harness writes both the serial and the parallel output of each workload to its
working directory and compares them. Over all of chr1 the genotype-query workload
alone produces a **~64 GB** TSV — 2504 samples wide — so the two copies together
need ~130 GB, plus room for the rest of the tier.

Recent distributions mount `/tmp` as a **tmpfs sized at roughly half of RAM**, which
is usually nowhere near enough. This changed underneath us: WSL2 kernel 6.6 kept
`/tmp` on the ext4 disk and the benchmark ran fine, while WSL2 kernel 6.18 mounts it
as tmpfs and the same machine class fails. Fedora 44 behaves like the latter.
Check before a long run:

```bash
df -h /tmp
```

A real failure of this kind looked like:

```
Filesystem      Size  Used Avail Use% Mounted on
tmpfs           7.8G  264K  7.8G   1% /tmp
```

7.8 GB against a 64 GB workload. The first workload passed, the 64 GB one filled the
filesystem, and every later workload failed for a reason that had nothing to do with
pbcftools.

Point the work directory somewhere with room:

```bash
TMPDIR=/path/with/space bash tests/run_all.sh <label>
TMPDIR=/path/with/space bash tests/run_tests.sh --benchmark --jobs 4,8,16,32
```

Or benchmark a smaller region — the speedup is just as meaningful:

```bash
bash tests/run_tests.sh --benchmark --geno-region 1:1-20000000 \
                                    --sites-region 1:1-20000000
```

`run_tests.sh` prints the working directory and its free space in its header and in
the report, and warns when a whole-chromosome benchmark will not fit. When anything
fails it now **keeps** the working directory and quotes the failing command's error
into the report, so the cause survives the run.

## What counts as "the same output"

`common.sh` compares more carefully than `cmp`, because a few differences are
correct and expected:

- **`; Date=`** inside `##bcftools_*Command` — the parallel run happens a moment
  later. The command text itself must still match exactly.
- **`##pbcftools_command`** — present only in the parallel output, and only when
  pbcftools actually parallelised (a passthrough command has none).
- **Header line order** — VCF gives meta lines no meaningful order beyond
  `##fileformat` first, and bcftools does not preserve it across formats. The set of
  lines must match exactly.
- **`# The command line was:`** in `roh` output — pbcftools rewrites it to name its
  own invocation. Every other comment line must match.
- **`stats` layout** — per-region results are merged by `plot-vcfstats -m`, which
  rewrites the preamble and reorders sections. Every counter must still match.

Everything else — every record, every data line, every other header line — must be
identical, and a missing or extra one fails the test.

`cnv` and `isec` are deliberately **not** in the region-parallel tiers: both run
unparallelized (see the Limitations section of the top-level `README.md`), so a
serial-vs-parallel timing comparison has nothing to compare. That they pass straight
through, and that their output is unchanged, is checked in `run_tests_safety.sh`.
