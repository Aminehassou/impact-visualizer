#!/usr/bin/env python3
"""
words_per_token sampling driver.

Three subcommands form the pipeline:

    list      pick a length-stratified random sample of mainspace articles
              per language; writes data/sample_<lang>.csv

    measure   for each sampled article, fetch WikiWho token count and
              rendered prose word count; writes data/measurements_<lang>.csv
              (resumable — already-measured page_ids are skipped)

    aggregate collapse all per-article measurements into per-language
              medians/quartiles/per-stratum stats; writes
              ../../config/words_per_token.yml

See README.md for usage; docs/words-per-token-methodology.md for the why.
"""
from __future__ import annotations

import argparse
import csv
import logging
import random
import re
import string
import statistics
import sys
import time
from dataclasses import dataclass
from pathlib import Path
from typing import Iterable, Iterator

import requests
import yaml
from lxml import html as lxml_html
from tqdm import tqdm

try:
    import icu  # PyICU
except ImportError:
    sys.stderr.write(
        "PyICU is required. Install ICU dev libs (libicu-dev / icu4c) "
        "and pip install PyICU.\n"
    )
    raise

# Languages currently supported by https://wikiwho-api.wmcloud.org/
# (verified via the WikiWho service homepage and live API probes). Keep
# in sync with lib/wiki_who_api.rb::AVAILABLE_WIKIPEDIAS. The homepage
# also links to `no`/`nb` but those return 404 in practice; `ro` and `sh`
# work but were not in the May 2026 study — add when sampled.
SUPPORTED_LANGS = [
    "ar", "ce", "cs", "de", "dsb", "en", "es", "eu", "fa", "fi",
    "fr", "hi", "hu", "id", "it", "ja", "nl", "pl", "pt",
    "ru", "sr", "sv", "tr", "uk", "vi", "zh",
]

METHODOLOGY_VERSION = 1

# Length strata in BYTES of wikitext (article size as reported by MW).
# Boundaries are inclusive-min, exclusive-max except the last bucket.
STRATA = [
    ("short",  1_000,  10_000),
    ("medium", 10_000, 50_000),
    ("long",   50_000, None),  # no upper bound
]

# Conservative default rate limits. WikiWho is hosted on Wikimedia Cloud
# and is happy to be polite to. MediaWiki action API tolerates more, but
# we don't need throughput.
DEFAULT_RATE_LIMIT_MW = 1.0
DEFAULT_RATE_LIMIT_WIKIWHO = 1.0

USER_AGENT = (
    "ImpactVisualizer/words-per-token-study "
    "(https://github.com/WikiEducationFoundation/impact-visualizer; "
    "sage@wikiedu.org)"
)

DATA_DIR = Path(__file__).resolve().parent / "data"
CONFIG_OUT = (
    Path(__file__).resolve().parent.parent.parent / "config" / "words_per_token.yml"
)

logging.basicConfig(
    level=logging.INFO,
    format="%(asctime)s %(levelname)s %(message)s",
    datefmt="%H:%M:%S",
)
log = logging.getLogger("words_per_token")


# --------------------------------------------------------------------------
# HTTP session helpers
# --------------------------------------------------------------------------

def _session() -> requests.Session:
    s = requests.Session()
    s.headers.update({"User-Agent": USER_AGENT, "Accept-Encoding": "gzip"})
    return s


def _mw_endpoint(lang: str) -> str:
    return f"https://{lang}.wikipedia.org/w/api.php"


def _wikiwho_url(lang: str, rev_id: int) -> str:
    return (
        f"https://wikiwho-api.wmcloud.org/{lang}/api/v1.0.0-beta/"
        f"rev_content/rev_id/{rev_id}/?editor=true&o_rev_id=true"
    )


def _get_json(session: requests.Session, url: str, params: dict | None = None,
              timeout: int = 60, retries: int = 3) -> dict:
    last_exc = None
    for attempt in range(retries):
        try:
            r = session.get(url, params=params, timeout=timeout)
            if r.status_code == 200:
                return r.json()
            if r.status_code in (400, 404, 408, 500):
                # WikiWho returns 500 for some text-suppressed revisions
                # and we want to skip those rather than abort the run.
                return {"_http_status": r.status_code}
            r.raise_for_status()
        except requests.RequestException as e:
            last_exc = e
            sleep = 3 ** (attempt + 1)
            log.warning("Request failed (%s), retrying in %ss", e, sleep)
            time.sleep(sleep)
    raise RuntimeError(f"Request failed after {retries} retries: {last_exc}")


# --------------------------------------------------------------------------
# Subcommand: list (pick a sample)
# --------------------------------------------------------------------------

@dataclass
class SampleRow:
    lang: str
    page_id: int
    title: str
    latest_rev_id: int
    bytes: int
    stratum: str

    @classmethod
    def header(cls) -> list[str]:
        return ["lang", "page_id", "title", "latest_rev_id", "bytes", "stratum"]

    def as_row(self) -> list:
        return [self.lang, self.page_id, self.title,
                self.latest_rev_id, self.bytes, self.stratum]


def _random_apfrom() -> str:
    """A short alphabetical seed used as the apfrom parameter to skip into
    a roughly-random position in the mainspace alphabetic listing."""
    # Two-letter prefix is enough to scatter starts across the alphabet.
    # ASCII range is fine; non-Latin wikis still index alphabetically with
    # MediaWiki's collation, but a Latin prefix lands somewhere reasonable
    # via the collation's fallback rules.
    return "".join(random.choices(string.ascii_lowercase, k=2))


def _fetch_allpages_batch(session: requests.Session, lang: str,
                          apfrom: str, apminsize: int,
                          apmaxsize: int | None,
                          aplimit: int = 500) -> list[dict]:
    params = {
        "action": "query",
        "format": "json",
        "formatversion": "2",
        "list": "allpages",
        "apnamespace": "0",
        "apfilterredir": "nonredirects",
        "apminsize": str(apminsize),
        "aplimit": str(aplimit),
        "apfrom": apfrom,
    }
    if apmaxsize is not None:
        params["apmaxsize"] = str(apmaxsize)
    data = _get_json(session, _mw_endpoint(lang), params=params)
    return data.get("query", {}).get("allpages", [])


def _filter_disambiguations(session: requests.Session, lang: str,
                            page_ids: list[int]) -> set[int]:
    """Return the subset of page_ids that are disambiguation pages."""
    disamb: set[int] = set()
    for chunk in _chunks(page_ids, 50):
        params = {
            "action": "query",
            "format": "json",
            "formatversion": "2",
            "prop": "pageprops",
            "ppprop": "disambiguation",
            "pageids": "|".join(str(p) for p in chunk),
        }
        data = _get_json(session, _mw_endpoint(lang), params=params)
        for page in data.get("query", {}).get("pages", []):
            if "pageprops" in page and "disambiguation" in page["pageprops"]:
                disamb.add(page["pageid"])
    return disamb


def _fetch_page_info(session: requests.Session, lang: str,
                     page_ids: list[int]) -> dict[int, dict]:
    """Returns {page_id: {"lastrevid": int, "length": int}} for each page.
    `prop=info` supports multi-page queries; `prop=revisions` with rvlimit
    does not. `length` is wikitext byte size — what we use for stratification.
    """
    out: dict[int, dict] = {}
    for chunk in _chunks(page_ids, 50):
        params = {
            "action": "query",
            "format": "json",
            "formatversion": "2",
            "prop": "info",
            "pageids": "|".join(str(p) for p in chunk),
        }
        data = _get_json(session, _mw_endpoint(lang), params=params)
        for page in data.get("query", {}).get("pages", []):
            if "missing" in page:
                continue
            out[page["pageid"]] = {
                "lastrevid": page.get("lastrevid"),
                "length": page.get("length"),
            }
    return out


def _chunks(seq: list, n: int) -> Iterator[list]:
    for i in range(0, len(seq), n):
        yield seq[i:i + n]


def sample_one_language(session: requests.Session, lang: str,
                        per_stratum: int, rate_limit_mw: float,
                        max_attempts_per_stratum: int = 20) -> list[SampleRow]:
    """Length-stratified random sample for one language.

    For each stratum, repeatedly pick a random apfrom, fetch up to
    ~500 pages with that prefix in the right size range, accumulate
    candidates, then randomly subsample to `per_stratum` after filtering
    out disambiguations. Bails out per-stratum after
    max_attempts_per_stratum if it can't find enough.
    """
    rows: list[SampleRow] = []
    for stratum_name, smin, smax in STRATA:
        candidates: dict[int, dict] = {}  # page_id -> page record
        attempts = 0
        target_pool_size = max(per_stratum * 4, 200)
        while len(candidates) < target_pool_size and attempts < max_attempts_per_stratum:
            attempts += 1
            apfrom = _random_apfrom()
            batch = _fetch_allpages_batch(session, lang, apfrom, smin, smax)
            time.sleep(rate_limit_mw)
            for page in batch:
                if page["pageid"] not in candidates:
                    candidates[page["pageid"]] = page
            log.debug("[%s/%s] attempt %d: pool=%d (apfrom=%r got %d)",
                      lang, stratum_name, attempts, len(candidates),
                      apfrom, len(batch))
        if len(candidates) < per_stratum:
            log.warning("[%s/%s] only found %d candidates (wanted %d) — "
                        "stratum will be undersampled",
                        lang, stratum_name, len(candidates), per_stratum)

        # Randomly draw 1.5x what we need so we can drop disambiguations
        draw_size = min(len(candidates), int(per_stratum * 1.5) + 5)
        drawn = random.sample(list(candidates.values()), draw_size)
        drawn_ids = [p["pageid"] for p in drawn]

        disambs = _filter_disambiguations(session, lang, drawn_ids)
        time.sleep(rate_limit_mw)
        kept = [p for p in drawn if p["pageid"] not in disambs]
        kept = kept[:per_stratum]

        infos = _fetch_page_info(session, lang, [p["pageid"] for p in kept])
        time.sleep(rate_limit_mw)

        for page in kept:
            info = infos.get(page["pageid"], {})
            rev_id = info.get("lastrevid")
            length = info.get("length")
            if rev_id is None or length is None:
                continue
            rows.append(SampleRow(
                lang=lang,
                page_id=page["pageid"],
                title=page["title"],
                latest_rev_id=rev_id,
                bytes=length,
                stratum=stratum_name,
            ))
        log.info("[%s/%s] sampled %d articles", lang, stratum_name, len(kept))
    return rows


def cmd_list(args: argparse.Namespace) -> None:
    if args.seed is not None:
        random.seed(args.seed)
    DATA_DIR.mkdir(exist_ok=True)
    session = _session()
    langs = SUPPORTED_LANGS if args.all else [args.lang]
    for lang in langs:
        out = DATA_DIR / f"sample_{lang}.csv"
        if out.exists() and not args.overwrite:
            log.info("[%s] %s already exists, skipping (use --overwrite)",
                      lang, out.name)
            continue
        log.info("[%s] sampling %d per stratum", lang, args.per_stratum)
        rows = sample_one_language(
            session, lang, args.per_stratum, args.rate_limit_mw,
        )
        with out.open("w", newline="", encoding="utf-8") as f:
            w = csv.writer(f)
            w.writerow(SampleRow.header())
            for r in rows:
                w.writerow(r.as_row())
        log.info("[%s] wrote %d rows to %s", lang, len(rows), out)


# --------------------------------------------------------------------------
# Subcommand: measure (token count + word count per article)
# --------------------------------------------------------------------------

# CSS-like selectors for elements to drop before computing word count.
# These are reader-visible-but-not-prose: footnote markers, edit links,
# navboxes, the reference list itself, hatnotes, and the like. Done with
# lxml's CSS-style queries through cssselect or via direct XPath.
DROP_SELECTORS = [
    'sup[class*="reference"]',
    'span[class*="mw-editsection"]',
    'div[class*="navbox"]',
    'div[class*="mw-references-wrap"]',
    'div[class*="reflist"]',
    'ol[class*="references"]',  # the <ol class="references">…</ol>
    'table[class*="navbox"]',
    'div[role="navigation"]',
    'style',
    'script',
]


def _strip_html_to_prose(html_str: str) -> str:
    """Drop non-prose subtrees and return the text content."""
    if not html_str:
        return ""
    try:
        tree = lxml_html.fragment_fromstring(html_str, create_parent="div")
    except Exception:
        # Defensive: occasionally MW returns content that lxml chokes on
        # without a wrapper. Wrap it ourselves.
        tree = lxml_html.fromstring(f"<div>{html_str}</div>")
    for sel in DROP_SELECTORS:
        for el in tree.cssselect(sel):
            parent = el.getparent()
            if parent is not None:
                parent.remove(el)
    text = tree.text_content() or ""
    # Collapse runs of whitespace; ICU handles newlines fine but this
    # makes truncated debugging output more readable.
    return re.sub(r"\s+", " ", text).strip()


def _icu_word_count(text: str, lang: str) -> int:
    """Count word-like segments using ICU's locale-aware BreakIterator.

    ICU rule statuses returned by getRuleStatus() are integer constants;
    the word-like ones live in [UBRK_WORD_NUMBER, UBRK_WORD_LIMIT) per the
    ICU docs. PyICU exposes these as icu.UBreakIteratorWordTag (an enum)
    but the integer ranges are stable.
    """
    if not text:
        return 0
    bi = icu.BreakIterator.createWordInstance(icu.Locale(lang))
    bi.setText(text)
    count = 0
    start = bi.first()
    for end in bi:
        status = bi.getRuleStatus()
        # ICU UBRK_WORD_* constants:
        #   NONE       = 0       (whitespace / punctuation segments)
        #   NONE_LIMIT = 100
        #   NUMBER     = 100..199 (word-like: contains a digit)
        #   LETTER     = 200..299 (word-like: alphabetic)
        #   KANA       = 300..399 (word-like: kana)
        #   IDEO       = 400..499 (word-like: CJK ideograph)
        # We count any status >= 100 as word-like.
        if status >= 100:
            count += 1
        start = end
    return count


def _count_wikiwho_tokens(session: requests.Session, lang: str,
                          rev_id: int) -> int | None:
    data = _get_json(session, _wikiwho_url(lang, rev_id))
    if "_http_status" in data:
        return None
    revs = data.get("revisions") or []
    if not revs:
        return None
    rev_dict = revs[0].get(str(rev_id)) or {}
    tokens = rev_dict.get("tokens")
    if tokens is None:
        return None
    return len(tokens)


def _fetch_rendered_html(session: requests.Session, lang: str,
                         page_id: int) -> str | None:
    params = {
        "action": "parse",
        "format": "json",
        "formatversion": "2",
        "pageid": str(page_id),
        "prop": "text",
        "disabletoc": "1",
        "disableeditsection": "1",
        "disablelimitreport": "1",
    }
    data = _get_json(session, _mw_endpoint(lang), params=params)
    if "_http_status" in data:
        return None
    return data.get("parse", {}).get("text")


def _measurements_path(lang: str) -> Path:
    return DATA_DIR / f"measurements_{lang}.csv"


MEASUREMENT_HEADER = [
    "lang", "page_id", "title", "latest_rev_id", "stratum",
    "tokens", "words", "tokens_per_word",
]


def _read_already_measured(lang: str) -> set[int]:
    p = _measurements_path(lang)
    if not p.exists():
        return set()
    seen: set[int] = set()
    with p.open(encoding="utf-8") as f:
        r = csv.DictReader(f)
        for row in r:
            seen.add(int(row["page_id"]))
    return seen


def _read_sample(lang: str) -> list[dict]:
    p = DATA_DIR / f"sample_{lang}.csv"
    if not p.exists():
        raise SystemExit(f"No sample for {lang}: run `list` first ({p}).")
    with p.open(encoding="utf-8") as f:
        return list(csv.DictReader(f))


def measure_one_language(session: requests.Session, lang: str,
                         rate_limit_mw: float,
                         rate_limit_wikiwho: float) -> None:
    sample = _read_sample(lang)
    already = _read_already_measured(lang)
    todo = [r for r in sample if int(r["page_id"]) not in already]
    if not todo:
        log.info("[%s] all %d articles already measured", lang, len(sample))
        return
    log.info("[%s] measuring %d articles (%d already done)",
              lang, len(todo), len(already))

    out = _measurements_path(lang)
    write_header = not out.exists()
    with out.open("a", newline="", encoding="utf-8") as f:
        w = csv.writer(f)
        if write_header:
            w.writerow(MEASUREMENT_HEADER)

        for row in tqdm(todo, desc=f"measure {lang}", unit="article"):
            page_id = int(row["page_id"])
            rev_id = int(row["latest_rev_id"])

            tokens = _count_wikiwho_tokens(session, lang, rev_id)
            time.sleep(rate_limit_wikiwho)
            if tokens is None or tokens <= 0:
                log.debug("[%s] skip page_id=%d (no WikiWho tokens)",
                          lang, page_id)
                continue

            html_str = _fetch_rendered_html(session, lang, page_id)
            time.sleep(rate_limit_mw)
            if html_str is None:
                log.debug("[%s] skip page_id=%d (no rendered HTML)",
                          lang, page_id)
                continue

            prose = _strip_html_to_prose(html_str)
            words = _icu_word_count(prose, lang)
            if words <= 0:
                log.debug("[%s] skip page_id=%d (zero words)",
                          lang, page_id)
                continue

            ratio = tokens / words
            w.writerow([
                lang, page_id, row["title"], rev_id, row["stratum"],
                tokens, words, f"{ratio:.6f}",
            ])
            f.flush()


def cmd_measure(args: argparse.Namespace) -> None:
    DATA_DIR.mkdir(exist_ok=True)
    session = _session()
    langs = SUPPORTED_LANGS if args.all else [args.lang]
    for lang in langs:
        sp = DATA_DIR / f"sample_{lang}.csv"
        if not sp.exists():
            log.warning("[%s] no sample, skipping", lang)
            continue
        measure_one_language(session, lang, args.rate_limit_mw,
                             args.rate_limit_wikiwho)


# --------------------------------------------------------------------------
# Subcommand: aggregate (write YAML)
# --------------------------------------------------------------------------

def _percentile(values: list[float], p: float) -> float:
    if not values:
        return 0.0
    s = sorted(values)
    k = (len(s) - 1) * p
    f = int(k)
    c = min(f + 1, len(s) - 1)
    if f == c:
        return s[f]
    return s[f] + (s[c] - s[f]) * (k - f)


def _aggregate_one_language(lang: str) -> dict | None:
    p = _measurements_path(lang)
    if not p.exists():
        return None
    rows = []
    with p.open(encoding="utf-8") as f:
        for row in csv.DictReader(f):
            try:
                row["tokens_per_word"] = float(row["tokens_per_word"])
                rows.append(row)
            except (KeyError, ValueError):
                continue
    if not rows:
        return None

    overall = [r["tokens_per_word"] for r in rows]
    by_stratum: dict[str, list[float]] = {}
    for r in rows:
        by_stratum.setdefault(r["stratum"], []).append(r["tokens_per_word"])

    summary: dict = {
        "n_total": len(overall),
        "median_tokens_per_word": round(statistics.median(overall), 4),
        "p25_tokens_per_word": round(_percentile(overall, 0.25), 4),
        "p75_tokens_per_word": round(_percentile(overall, 0.75), 4),
        "mean_tokens_per_word": round(statistics.fmean(overall), 4),
        "stdev_tokens_per_word": (
            round(statistics.stdev(overall), 4) if len(overall) > 1 else 0.0
        ),
        "by_stratum": {},
    }
    for stratum_name, _, _ in STRATA:
        vals = by_stratum.get(stratum_name, [])
        if vals:
            summary["by_stratum"][stratum_name] = {
                "n": len(vals),
                "median": round(statistics.median(vals), 4),
            }
        else:
            summary["by_stratum"][stratum_name] = {"n": 0, "median": None}
    return summary


def cmd_aggregate(args: argparse.Namespace) -> None:
    out: dict = {
        "_meta": {
            "methodology_version": METHODOLOGY_VERSION,
            "sampled_at": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()),
            "notes": (
                "Per-language tokens_per_word ratios. Numerator = WikiWho "
                "tokens on raw wikitext; denominator = ICU-segmented words "
                "in rendered article prose. See "
                "docs/words-per-token-methodology.md."
            ),
        },
        "languages": {},
    }
    for lang in SUPPORTED_LANGS:
        summary = _aggregate_one_language(lang)
        if summary:
            out["languages"][lang] = summary

    CONFIG_OUT.parent.mkdir(parents=True, exist_ok=True)
    with CONFIG_OUT.open("w", encoding="utf-8") as f:
        yaml.safe_dump(out, f, sort_keys=True, allow_unicode=True)
    log.info("Wrote %d languages to %s", len(out["languages"]), CONFIG_OUT)


# --------------------------------------------------------------------------
# CLI plumbing
# --------------------------------------------------------------------------

def main(argv: list[str] | None = None) -> None:
    p = argparse.ArgumentParser(prog="sample.py", description=__doc__,
                                formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = p.add_subparsers(dest="cmd", required=True)

    common = argparse.ArgumentParser(add_help=False)
    common.add_argument("--lang", help="Single language code (e.g. en).")
    common.add_argument("--all", action="store_true",
                        help="Run for all supported languages.")
    common.add_argument("--rate-limit-mw", type=float,
                        default=DEFAULT_RATE_LIMIT_MW,
                        help=f"Sleep between MW calls (default {DEFAULT_RATE_LIMIT_MW}s).")
    common.add_argument("--rate-limit-wikiwho", type=float,
                        default=DEFAULT_RATE_LIMIT_WIKIWHO,
                        help=f"Sleep between WikiWho calls (default {DEFAULT_RATE_LIMIT_WIKIWHO}s).")

    pl = sub.add_parser("list", parents=[common], help="Pick a sample.")
    pl.add_argument("--per-stratum", type=int, default=100,
                    help="Articles to sample per length stratum (default 100).")
    pl.add_argument("--seed", type=int, default=None,
                    help="Random seed for reproducibility.")
    pl.add_argument("--overwrite", action="store_true",
                    help="Re-pick sample even if sample_<lang>.csv already exists.")
    pl.set_defaults(func=cmd_list)

    pm = sub.add_parser("measure", parents=[common], help="Measure samples.")
    pm.set_defaults(func=cmd_measure)

    pa = sub.add_parser("aggregate", help="Write the aggregated YAML.")
    pa.set_defaults(func=cmd_aggregate)

    args = p.parse_args(argv)

    if args.cmd in ("list", "measure"):
        if not args.all and not args.lang:
            p.error("--lang or --all is required for `%s`" % args.cmd)
        if args.all and args.lang:
            p.error("--lang and --all are mutually exclusive")

    args.func(args)


if __name__ == "__main__":
    main()
