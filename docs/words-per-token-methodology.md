# Words-per-token methodology

This document describes how Impact Visualizer derives the per-language
`tokens_per_word` divisor that converts WikiWho token counts into
reader-facing word counts in the UI. It accompanies the empirical study
in `scripts/words_per_token/` and the per-language defaults in
`config/words_per_token.yml`.

## Why a study at all

WikiWho is the only authoritative source of attribution-aware revision
deltas for IV. Its output is "tokens" — fragments of wikitext, not the
words a reader sees. Treating tokens as a proxy for words requires a
divisor; getting that divisor right (and *honest* about its uncertainty)
is the difference between a misleading number and a defensible one.

WikiWho's tokenizer (see
`WikiWho/utils.py::split_into_tokens` in
`github.com/wikimedia/wikiwho_api`) is **language-agnostic**: it splits
on whitespace and a fixed list of Latin / symbol punctuation. CJK
sentence punctuation (`。 、 「 」`) and the Devanagari danda (`।`) are
not in that list, so the same tokenizer produces wildly different
token-density across languages.

A single global ratio cannot be honest; per-language ratios are
required.

## What "words" means here

The published ratio is intentionally asymmetric:

- **Numerator (tokens)**: count of tokens emitted by WikiWho on the
  *raw wikitext* of the article — the same number IV's pipeline already
  records via `ArticleTokenService`.
- **Denominator (words)**: count of word-like segments in the
  *rendered article prose* (templates expanded, refs and edit-section
  markers stripped), segmented with ICU's locale-aware
  `BreakIterator.createWordInstance(Locale(lang))`.

This matches the practical conversion the UI is performing: given a
token count from WikiWho, how many reader-visible prose words is that?
The numerator includes markup overhead (template names, ref tags, URL
fragments); the denominator does not. That asymmetry is the point — the
ratio absorbs the markup overhead so the reader sees a sensible number.

## Languages covered

All 27 Wikipedias supported by the live WikiWho service at
`wikiwho-api.wmcloud.org` (verified against the service homepage):

```
ar, ce, cs, de, dsb, en, es, eu, fa, fi, fr, hi, hu, id, it, ja, nl,
no, pl, pt, ru, sr, sv, tr, uk, vi, zh
```

This list is mirrored in `lib/wiki_who_api.rb::AVAILABLE_WIKIPEDIAS`
and in `scripts/words_per_token/sample.py::SUPPORTED_LANGS` — both must
be updated together when WikiWho's coverage changes.

## Sampling design

Per language:

- **Universe**: mainspace pages only (`namespace=0`), redirects and
  disambiguations excluded.
- **Length stratification** (by wikitext byte size, the `length` field
  returned by `prop=info`):
  - **short**: 1 KB – 10 KB
  - **medium**: 10 KB – 50 KB
  - **long**: > 50 KB
  - articles smaller than 1 KB are excluded as essentially-empty stubs
    (their ratios are dominated by single-citation noise).
- **Per-stratum sample size**: 100 articles → 300 articles per language.
- **Selection method**: at each attempt, pick a random two-letter
  alphabetical prefix and request a 500-page slice from
  `list=allpages&apnamespace=0&apfilterredir=nonredirects&apminsize=…&apmaxsize=…&apfrom=<prefix>`.
  Repeat until the candidate pool is at least ~4× the per-stratum target;
  randomly subsample. Disambiguation pages are filtered out via a
  `prop=pageprops&ppprop=disambiguation` lookup before drawing the final
  sample.

Length stratification (rather than quality-class stratification) was
chosen because:

1. Long articles dominate IV's token totals, so the ratio at long-article
   scale matters more than at stub scale; oversampling longer articles
   reflects the population of bytes IV actually meters.
2. Quality classes (FA / GA / B / etc.) are unevenly applied across
   the 27 wikis. Length is a fair, language-portable proxy.

## Word counting

Per article:

1. Fetch fully rendered HTML via
   `action=parse&pageid=<id>&prop=text&disabletoc=1&disableeditsection=1&disablelimitreport=1&formatversion=2`.
   This gives the same content a reader sees on the article page —
   templates expanded, infoboxes / tables / captions present as text.
2. Drop these subtrees before counting (they are reader-visible-but-
   not-prose):
   - `sup.reference` (footnote markers `[1]`, `[2]`)
   - `span.mw-editsection` (edit-section links)
   - `div.navbox`, `table.navbox` (bottom-of-page nav templates)
   - `div.mw-references-wrap`, `div.reflist`, `ol.references`
     (the reference list itself — its prose is not authored prose
     proper)
   - `div[role="navigation"]`, `style`, `script`
3. Segment the remaining `text_content()` with PyICU
   `BreakIterator.createWordInstance(Locale(lang))`. Count breaks where
   `getRuleStatus()` ≥ 100 (ICU's word-like statuses:
   `UBRK_WORD_NUMBER`, `_LETTER`, `_KANA`, `_IDEO`).

`prop=extracts` (TextExtracts extension) is **deliberately not used**:
it strips infoboxes and some tables, which undercounts reader-facing
prose for any article whose substance lives in structured templates
(geography, biography, taxa, etc.).

ICU is chosen over MeCab (ja) and jieba (zh) for **uniformity** — one
segmenter covers all 27 wikis, methodology stays comparable across
languages, no per-language native dependencies. ICU's CJK segmentation
is dictionary-based but not state-of-the-art; published ja/zh medians
should be treated as defensible-but-rough. If we ever need higher
fidelity for those languages we can revisit (logged as future work).

## Aggregation

Per language we publish:

- `n_total`, plus per-stratum `n` (short / medium / long)
- `median_tokens_per_word` (overall and per stratum) — **the number
  consumed by the Rails app**
- `p25` / `p75` (overall) — the IQR; useful for sanity-checking outliers
- `mean`, `stdev` (overall) — informational; the per-article
  distribution is right-skewed because reference-heavy articles inflate
  token counts asymmetrically.

The median is published rather than the mean because the right-skew
from URL/citation-heavy articles (each URL contributes many tokens —
`http`, `:`, `/`, `/`, `www`, `.`, etc. each count) makes the mean a
poor central tendency.

## How to refresh

```sh
cd scripts/words_per_token
python3 -m venv .venv && source .venv/bin/activate
pip install -r requirements.txt        # needs libicu-dev installed

python sample.py list --all --per-stratum 100
python sample.py measure --all
python sample.py aggregate              # writes config/words_per_token.yml
```

Expected runtime: ~2–3 hours at the default 1 req/sec MW + 1 req/sec
WikiWho rate limits, dominated by the `measure` step (8,100 articles
× 2 calls each). `measure` is resumable: re-running picks up where it
left off based on already-seen `page_id`s in `data/measurements_<lang>.csv`.

When refreshing, bump `METHODOLOGY_VERSION` in
`scripts/words_per_token/sample.py` if anything about sampling design or
word definition changes; otherwise leave it alone so consumers can tell
the methodology hasn't drifted.

## Known limitations

- **CJK segmentation**: see above — ICU's dictionary-based segmenter
  for ja/zh is not as accurate as MeCab/jieba. Median is still
  defensible because errors cancel across the sample, but per-article
  ratios for those languages should not be trusted in isolation.
- **Reference list density**: articles dominated by their reference
  list (e.g., niche biographies) produce inflated ratios because the
  bibliography contributes many wikitext tokens per rendered word.
  Length stratification + median aggregation absorb most of this; the
  IQR makes residual skew visible.
- **Population vs edit-volume weighting**: we sample article
  *populations*, not byte-weighted articles. IV in practice operates
  on subsets of articles drawn from topics — the relative balance of
  long vs short articles in any given topic may differ from the wiki-
  wide population. Per-stratum medians are reported so operators can
  gauge sensitivity.
- **Time freshness**: ratios are measured against the latest revision
  at the time the study runs. If wiki-wide writing style or
  citation density changes substantially, the ratios drift; refresh
  annually or when MediaWiki rendering changes materially.

## Future work

- Per-language refinement of CJK segmentation (MeCab / jieba) if
  eyeball checks suggest the ICU numbers are systematically off.
- Per-topic measurement (deriving the ratio from the topic's own
  articles instead of the language default) — only worth pursuing if a
  topic's per-stratum mix differs dramatically from the wiki-wide
  sample.

## Results

Per-language medians (sample size, IQR) are stored in
`config/words_per_token.yml` — that file is the source of truth.
The table below is a human-readable snapshot.

**Methodology version 1, sampled 2026-05-09. Per-stratum
target n=100; total 300 (n_total may be slightly lower when
articles failed WikiWho/MW lookups).**

Sorted by overall median, ascending:

| Lang | n   | Median | p25–p75    | Short | Medium | Long |
|------|-----|--------|------------|-------|--------|------|
| ja   | 300 | 1.60   | 1.09–2.46  | 1.55  | 1.81   | 1.47 |
| fa   | 297 | 2.51   | 2.06–3.78  | 2.23  | 3.13   | 2.97 |
| ar   | 295 | 2.56   | 2.00–5.18  | 2.04  | 2.85   | 5.16 |
| hi   | 300 | 2.73   | 1.72–4.63  | 2.95  | 2.44   | 2.54 |
| dsb  | 154 | 2.85   | 2.24–3.63  | 2.69  | 3.12   | 3.12 |
| de   | 300 | 2.87   | 2.21–3.99  | 2.88  | 2.85   | 2.81 |
| fr   | 300 | 2.91   | 2.32–3.91  | 2.44  | 3.46   | 2.89 |
| nl   | 294 | 3.04   | 2.17–4.19  | 3.17  | 2.43   | 3.69 |
| es   | 300 | 3.08   | 2.31–4.26  | 2.67  | 3.45   | 3.17 |
| it   | 295 | 3.09   | 2.30–4.61  | 2.51  | 3.25   | 3.59 |
| hu   | 299 | 3.09   | 2.13–4.63  | 2.46  | 3.16   | 3.88 |
| eu   | 299 | 3.16   | 2.33–4.30  | 3.06  | 2.97   | 3.57 |
| vi   | 300 | 3.29   | 2.37–5.02  | 4.09  | 2.53   | 3.51 |
| cs   | 298 | 3.37   | 2.38–4.87  | 2.89  | 3.18   | 4.19 |
| sr   | 296 | 3.58   | 2.38–5.26  | 3.53  | 3.62   | 3.61 |
| fi   | 298 | 3.64   | 2.64–4.91  | 3.61  | 3.41   | 3.98 |
| en   | 295 | 3.65   | 2.77–4.90  | 3.47  | 3.21   | 4.04 |
| pl   | 283 | 3.67   | 2.66–5.85  | 2.67  | 4.66   | 4.78 |
| ru   | 298 | 3.76   | 2.56–6.32  | 3.11  | 3.93   | 5.07 |
| zh   | 271 | 3.91   | 2.96–5.98  | 3.60  | 3.96   | 4.10 |
| pt   | 297 | 4.00   | 2.77–5.25  | 3.59  | 3.49   | 4.77 |
| id   | 293 | 4.44   | 2.91–6.19  | 3.38  | 4.02   | 5.59 |
| uk   | 299 | 4.51   | 3.00–6.88  | 3.57  | 5.75   | 5.06 |
| sv   | 294 | 4.60   | 2.75–6.99  | 7.28  | 3.07   | 4.09 |
| tr   | 293 | 4.78   | 3.52–7.06  | 4.48  | 4.64   | 5.35 |
| ce   | 299 | 5.20   | 4.54–6.53  | 4.76  | 5.91   | 9.18 |

### Surprises and notes

- **`zh` is not the predicted outlier** — Chinese sits at 3.91, in the
  middle of the pack. The CJK-no-whitespace effect *is* present (token
  count is suppressed for pure-Chinese runs), but Chinese Wikipedia
  articles include enough Latin-script citations, URLs, infobox
  fields, and template names to bring the wikitext token count back
  up. ICU's CJK segmentation is doing reasonable work on the rendered
  prose. ja, by contrast, lands at 1.60 — meaningfully lower than en
  (3.65), confirming the predicted asymmetry but in muted form.
- **High-ratio cluster (uk, sv, tr, ce, id, pt)** — these wikis have
  tokens-per-word ratios noticeably above en. Drivers vary:
  `ce` (Chechen) is a small wiki with bot-generated mass-produced
  pages where the ratio is dominated by reference templates;
  `sv` (Swedish) has Lsjbot-generated geography stubs with infobox-
  heavy short articles (note the short-stratum spike: 7.28); `tr`
  and `id` are both heavily citation-templated.
- **Low-ratio outliers (ja, fa, ar, hi)** — these are the languages
  where applying en's 3.25 default would *significantly* understate
  the displayed word count. ja in particular: a Japanese topic
  showing 100k tokens with the old 3.25 divisor would render as ~31k
  words, when the empirically-correct figure is ~63k.
- **`dsb` (Lower Sorbian) is undersampled** (n=154, only 3 long-
  stratum articles in existence). Its median is reasonable but
  should be treated as low-confidence.
- **Per-stratum variation within a language** is sometimes large
  (`ar` short=2.04 vs long=5.16; `pl` short=2.67 vs long=4.78). This
  reflects that long articles concentrate references and templates.
  We publish the overall median because that's the conservative
  central tendency for IV's mixed-length topics.

### Languages on the WikiWho service but not in this study

The WikiWho homepage links to `no` and `nb` (Norwegian) but the API
returns 404 for both. They are excluded from
`AVAILABLE_WIKIPEDIAS`. Two languages — `ro` (Romanian) and `sh`
(Serbo-Croatian) — *do* return data but were not in this round's
sample list and so are not yet published; they should be added when
the study is refreshed. WikiWho is gradually expanding language
support, so periodic re-checks of the service homepage are worth
doing.
