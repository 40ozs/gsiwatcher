#!/usr/bin/env python3
"""
UMich GSI Posting Watcher CLI

Monitors:
1. UMich Careers career-interest pages
2. UMSI Graduate Student Instructor Google Sites open postings page

Examples:
    python umich_gsi_watch.py --show-all
    python umich_gsi_watch.py --source careers --career-interest-id 171
    python umich_gsi_watch.py --source umsi
    python umich_gsi_watch.py --format json
"""

from __future__ import annotations

import argparse
import csv
import json
import logging
import re
import sys
from dataclasses import asdict, dataclass
from datetime import datetime, timezone
from pathlib import Path
from typing import Iterable, Literal
from urllib.parse import urljoin

import requests
from bs4 import BeautifulSoup

BASE_URL = "https://careers.umich.edu"
DEFAULT_TIMEOUT_SECONDS = 30
UMSI_GSI_COURSES_URL = (
    "https://sites.google.com/a/umich.edu/"
    "umsi-graduate-student-instructors/courses?authuser=0"
)
KNOWN_LOCATIONS = (
    "Ann Arbor Campus",
    "Dearborn Campus",
    "Flint Campus",
    "Multiple Locations",
    "Other MI Location",
    "Outside Michigan",
)
OutputFormat = Literal["text", "json", "csv"]


@dataclass(frozen=True, slots=True)
class UnifiedPosting:
    source: str
    title: str
    job_opening_id: str | None
    url: str
    date_posted: str | None = None
    department: str | None = None
    location: str | None = None
    status: str | None = None
    course: str | None = None


@dataclass(frozen=True, slots=True)
class WatchState:
    updated_at_utc: str
    seen_posting_keys: list[str]


class WatcherError(Exception):
    """Base exception for watcher errors."""


class FetchError(WatcherError):
    """Raised when a page cannot be fetched."""


def fetch_html(url: str, timeout: int = DEFAULT_TIMEOUT_SECONDS) -> str:
    try:
        response = requests.get(
            url,
            timeout=timeout,
            headers={"User-Agent": "UMichGsiWatcherCLI/1.0"},
        )
        response.raise_for_status()
        return response.text
    except requests.RequestException as exc:
        raise FetchError(f"Failed to fetch page: {url}") from exc


def normalize_whitespace(value: str) -> str:
    return re.sub(r"\s+", " ", value).strip()


def current_utc_timestamp() -> str:
    return datetime.now(timezone.utc).isoformat(timespec="seconds")


def get_posting_key(posting: UnifiedPosting) -> str:
    if posting.job_opening_id:
        return f"{posting.source}:job:{posting.job_opening_id}"
    return f"{posting.source}:url:{posting.url}"


def get_career_interest_url(career_interest_id: int) -> str:
    return f"{BASE_URL}/browse-jobs/career_interests/{career_interest_id}"


def get_job_detail_url(job_opening_id: str) -> str:
    return f"{BASE_URL}/job_detail/{job_opening_id}"


def parse_umich_careers_jobs(html: str, career_interest_id: int) -> list[UnifiedPosting]:
    soup = BeautifulSoup(html, "html.parser")
    text = soup.get_text(" ", strip=True)
    location_pattern = "|".join(re.escape(location) for location in KNOWN_LOCATIONS)
    pattern = re.compile(
        rf"(?P<date>\d{{1,2}}/\d{{1,2}}/\d{{4}})\s+"
        rf"(?P<title>.+?)\s+"
        rf"(?P<id>\d{{6}})\s+"
        rf"(?P<department>.+?)\s+"
        rf"(?P<location>{location_pattern})",
        re.IGNORECASE,
    )
    postings: list[UnifiedPosting] = []
    for match in pattern.finditer(text):
        job_id = normalize_whitespace(match.group("id"))
        postings.append(
            UnifiedPosting(
                source=f"umich_careers:{career_interest_id}",
                title=normalize_whitespace(match.group("title")),
                job_opening_id=job_id,
                date_posted=normalize_whitespace(match.group("date")),
                department=normalize_whitespace(match.group("department")),
                location=normalize_whitespace(match.group("location")),
                status=None,
                course=None,
                url=get_job_detail_url(job_id),
            )
        )
    return dedupe_postings(postings)


def get_umich_career_interest_postings(
    career_interest_id: int,
    timeout: int = DEFAULT_TIMEOUT_SECONDS,
) -> list[UnifiedPosting]:
    html = fetch_html(get_career_interest_url(career_interest_id), timeout=timeout)
    return parse_umich_careers_jobs(html, career_interest_id)


def parse_umsi_open_course_links(html: str, base_url: str) -> list[tuple[str, str]]:
    soup = BeautifulSoup(html, "html.parser")
    text = soup.get_text("\n", strip=True)
    if "OPEN POSTINGS:" not in text:
        return []
    open_section = text.split("OPEN POSTINGS:", 1)[1]
    if "CLOSED POSTINGS:" in open_section:
        open_section = open_section.split("CLOSED POSTINGS:", 1)[0]
    open_course_names = {
        line.strip()
        for line in open_section.splitlines()
        if line.strip() and line.strip().lower() not in {"courses:", "courses"}
    }
    results: list[tuple[str, str]] = []
    for link in soup.find_all("a", href=True):
        title = link.get_text(" ", strip=True)
        if title in open_course_names:
            results.append((title, urljoin(base_url, link["href"])))
    seen: set[str] = set()
    unique: list[tuple[str, str]] = []
    for title, url in results:
        key = f"{title}|{url}"
        if key in seen:
            continue
        seen.add(key)
        unique.append((title, url))
    return unique


def parse_job_opening_id_from_detail_page(html: str) -> str | None:
    text = BeautifulSoup(html, "html.parser").get_text(" ", strip=True)
    patterns = [
        r"Job Opening ID\s*#?\s*(\d{6})",
        r"Job Opening ID\s+(\d{6})",
        r"Enter the Job Opening ID\s*#?\s*(\d{6})",
    ]
    for pattern in patterns:
        match = re.search(pattern, text, flags=re.IGNORECASE)
        if match:
            return match.group(1)
    return None


def get_umsi_open_gsi_postings(timeout: int = DEFAULT_TIMEOUT_SECONDS) -> list[UnifiedPosting]:
    courses_html = fetch_html(UMSI_GSI_COURSES_URL, timeout=timeout)
    open_courses = parse_umsi_open_course_links(courses_html, UMSI_GSI_COURSES_URL)
    postings: list[UnifiedPosting] = []
    for course_title, detail_url in open_courses:
        detail_html = fetch_html(detail_url, timeout=timeout)
        job_opening_id = parse_job_opening_id_from_detail_page(detail_html)
        postings.append(
            UnifiedPosting(
                source="umsi_google_sites",
                title=course_title,
                job_opening_id=job_opening_id,
                url=detail_url,
                date_posted=None,
                department="UMSI",
                location=None,
                status="OPEN",
                course=course_title,
            )
        )
    return dedupe_postings(postings)


def dedupe_postings(postings: Iterable[UnifiedPosting]) -> list[UnifiedPosting]:
    seen: set[str] = set()
    unique: list[UnifiedPosting] = []
    for posting in postings:
        key = get_posting_key(posting)
        if key in seen:
            continue
        seen.add(key)
        unique.append(posting)
    return unique


def load_state(state_path: Path) -> WatchState:
    if not state_path.exists():
        return WatchState(updated_at_utc=current_utc_timestamp(), seen_posting_keys=[])
    try:
        raw = json.loads(state_path.read_text(encoding="utf-8"))
        if isinstance(raw, list):
            return WatchState(
                updated_at_utc=current_utc_timestamp(),
                seen_posting_keys=sorted({str(item) for item in raw}),
            )
        if not isinstance(raw, dict):
            raise ValueError("State file must contain either a list or an object.")
        keys = raw.get("seen_posting_keys", [])
        if not isinstance(keys, list):
            raise ValueError("State field 'seen_posting_keys' must be a list.")
        return WatchState(
            updated_at_utc=str(raw.get("updated_at_utc", current_utc_timestamp())),
            seen_posting_keys=sorted({str(item) for item in keys}),
        )
    except (json.JSONDecodeError, OSError, ValueError) as exc:
        raise WatcherError(f"Failed to read state file: {state_path}") from exc


def save_state(state_path: Path, postings: Iterable[UnifiedPosting]) -> None:
    state = WatchState(
        updated_at_utc=current_utc_timestamp(),
        seen_posting_keys=sorted({get_posting_key(posting) for posting in postings}),
    )
    state_path.parent.mkdir(parents=True, exist_ok=True)
    temp_path = state_path.with_suffix(f"{state_path.suffix}.tmp")
    temp_path.write_text(json.dumps(asdict(state), indent=2), encoding="utf-8")
    temp_path.replace(state_path)


def find_new_postings(
    postings: Iterable[UnifiedPosting],
    seen_posting_keys: Iterable[str],
) -> list[UnifiedPosting]:
    seen = set(seen_posting_keys)
    return [posting for posting in postings if get_posting_key(posting) not in seen]


def write_text_output(postings: list[UnifiedPosting], *, heading: str) -> None:
    if not postings:
        print("No postings to display.")
        return
    print(heading)
    print()
    for posting in postings:
        print(posting.title)
        if posting.status:
            print(f"Status:     {posting.status}")
        if posting.date_posted:
            print(f"Posted:     {posting.date_posted}")
        if posting.job_opening_id:
            print(f"Job ID:     {posting.job_opening_id}")
        if posting.department:
            print(f"Department: {posting.department}")
        if posting.location:
            print(f"Location:   {posting.location}")
        if posting.course:
            print(f"Course:     {posting.course}")
        print(f"Source:     {posting.source}")
        print(f"URL:        {posting.url}")
        print("-" * 80)


def write_json_output(postings: list[UnifiedPosting]) -> None:
    print(json.dumps([asdict(posting) for posting in postings], indent=2))


def write_csv_output(postings: list[UnifiedPosting]) -> None:
    writer = csv.DictWriter(
        sys.stdout,
        fieldnames=[
            "source",
            "title",
            "job_opening_id",
            "date_posted",
            "department",
            "location",
            "status",
            "course",
            "url",
        ],
    )
    writer.writeheader()
    for posting in postings:
        writer.writerow(asdict(posting))


def write_output(postings: list[UnifiedPosting], output_format: OutputFormat, *, heading: str) -> None:
    if output_format == "text":
        write_text_output(postings, heading=heading)
    elif output_format == "json":
        write_json_output(postings)
    elif output_format == "csv":
        write_csv_output(postings)
    else:
        raise ValueError(f"Unsupported output format: {output_format}")


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description="Watch UMich Careers and UMSI GSI postings.")
    parser.add_argument("--career-interest-id", type=int, default=171, help="UMich Careers career interest ID. Default: 171.")
    parser.add_argument("--state-path", type=Path, default=Path("umich-gsi-seen-postings.json"), help="Path to the local JSON state file.")
    parser.add_argument("--source", choices=["all", "careers", "umsi"], default="all", help="Which source to check. Default: all.")
    parser.add_argument("--show-all", action="store_true", help="Show all current postings instead of only new postings.")
    parser.add_argument("--format", choices=["text", "json", "csv"], default="text", help="Output format.")
    parser.add_argument("--timeout", type=int, default=DEFAULT_TIMEOUT_SECONDS, help="HTTP timeout in seconds.")
    parser.add_argument("--no-save-state", action="store_true", help="Do not update the local state file after checking.")
    parser.add_argument("--verbose", action="store_true", help="Enable verbose logging.")
    return parser.parse_args()


def configure_logging(verbose: bool) -> None:
    logging.basicConfig(level=logging.DEBUG if verbose else logging.WARNING, format="%(levelname)s: %(message)s")


def collect_postings(args: argparse.Namespace) -> list[UnifiedPosting]:
    postings: list[UnifiedPosting] = []
    if args.source in {"all", "careers"}:
        postings.extend(get_umich_career_interest_postings(args.career_interest_id, args.timeout))
    if args.source in {"all", "umsi"}:
        postings.extend(get_umsi_open_gsi_postings(args.timeout))
    return dedupe_postings(postings)


def main() -> int:
    args = parse_args()
    configure_logging(args.verbose)
    try:
        state = load_state(args.state_path)
        postings = collect_postings(args)
        new_postings = find_new_postings(postings, state.seen_posting_keys)
        postings_to_display = postings if args.show_all else new_postings
        heading = "All current postings:" if args.show_all else "New postings:"
        if not postings_to_display and args.format == "text":
            print("No new postings found." if not args.show_all else "No postings found.")
        else:
            write_output(postings_to_display, args.format, heading=heading)
        if not args.no_save_state:
            save_state(args.state_path, postings)
        return 0
    except WatcherError as exc:
        print(f"Error: {exc}", file=sys.stderr)
        return 1
    except KeyboardInterrupt:
        print("Cancelled.", file=sys.stderr)
        return 130


if __name__ == "__main__":
    raise SystemExit(main())
