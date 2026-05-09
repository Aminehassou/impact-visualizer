# words_per_token

Empirical study tool for deriving per-language `tokens_per_word` ratios used
by Impact Visualizer to convert WikiWho token counts into reader-facing word
counts.

See `docs/words-per-token-methodology.md` for the methodology writeup,
sample sizes, and results table. This README is just the operator's guide.

## What it does

For each Wikipedia language supported by WikiWho (27 as of writing), pulls
a length-stratified random sample of mainspace articles, fetches:

- the **WikiWho token count** at the latest revision (numerator), and
- the **rendered prose word count** of the article HTML (denominator),
  segmented with ICU's locale-aware word break iterator,

and aggregates the per-article ratio into a single `tokens_per_word`
median per language. Output goes to `../../config/words_per_token.yml`,
which the Rails app reads via `Wiki#tokens_per_word_default`.

## Setup

```sh
cd scripts/words_per_token
python3 -m venv .venv
source .venv/bin/activate
pip install -r requirements.txt
```

PyICU requires the ICU dev libraries on your system. On Debian/Ubuntu:

```sh
sudo apt install libicu-dev pkg-config
```

## Usage

The pipeline is three subcommands. All write to `data/` (sample CSVs are
committed; measurement CSVs are gitignored — re-derivable from sample IDs).

### 1. Pick a sample

```sh
python sample.py list --lang en --per-stratum 100
# → data/sample_en.csv
```

`--per-stratum N` controls how many articles to draw per length bucket
(short / medium / long). `--seed` is accepted for reproducibility.

To list all languages at once:

```sh
python sample.py list --all --per-stratum 100
```

### 2. Measure

```sh
python sample.py measure --lang en
# → data/measurements_en.csv (gitignored)
```

For each row of `sample_<lang>.csv`, hits the WikiWho API for token count
and the MediaWiki action API for rendered HTML, computes
`tokens_per_word`, and writes a per-article CSV. Resumable — already-
measured page_ids are skipped.

`--rate-limit-mw` and `--rate-limit-wikiwho` control sleep between calls
(default 1.0s each).

### 3. Aggregate

```sh
python sample.py aggregate
# → ../../config/words_per_token.yml
```

Reads every `data/measurements_*.csv` and emits per-language medians,
quartiles, and per-stratum breakdowns. Re-running this is cheap; do it
after each `measure` run finishes.

## Refreshing

Re-running the full study from scratch:

```sh
rm data/sample_*.csv data/measurements_*.csv
python sample.py list --all --per-stratum 100
python sample.py measure --all
python sample.py aggregate
```

When refreshing, bump `methodology_version` in `sample.py` if anything
about the sampling design or word definition changed; otherwise leave
it alone.

## Limitations

- ICU's CJK segmentation (ja, zh) is dictionary-based but not as accurate
  as MeCab/jieba. The published medians for those languages should be
  treated as defensible-but-rough.
- We sample article *populations*, not edit-volume-weighted articles.
  The IV use case sees more long articles than the population mean
  suggests; length stratification partially corrects for this. The
  per-stratum medians in the output let you sanity-check.
- WikiWho's tokenizer is the bundled
  `WikiWho/utils.py::split_into_tokens`. Ratios are tied to that
  implementation; if WikiWho's tokenizer changes upstream the study
  must be re-run.
