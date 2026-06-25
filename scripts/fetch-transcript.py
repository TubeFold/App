#!/usr/bin/env python3
from __future__ import annotations

import argparse
import json
from pathlib import Path

from youtube_summary_lib import parse_bool
from youtube_transcript_source import TranscriptError, ensure_transcript_text, fetch_transcript


def main() -> int:
    parser = argparse.ArgumentParser(description="Fetch YouTube transcript as plain text")
    parser.add_argument("video_id")
    parser.add_argument("output_text", type=Path)
    parser.add_argument("info_json", type=Path)
    parser.add_argument("--requested-language")
    parser.add_argument("--preferred-langs", default="pl,ru,en")
    parser.add_argument("--allow-any", default="true")
    args = parser.parse_args()

    try:
        result = fetch_transcript(
            args.video_id,
            requested_language=args.requested_language,
            preferred_langs=args.preferred_langs,
            allow_any=parse_bool(args.allow_any, default=True),
        )
        ensure_transcript_text(result)
    except TranscriptError as error:
        raise SystemExit(f"[ERROR] {error}") from error

    args.output_text.write_text(result.text.rstrip() + "\n", encoding="utf-8")
    args.info_json.write_text(
        json.dumps(
            {
                "language": result.language,
                "language_code": result.language_code,
                "is_generated": result.is_generated,
            },
            ensure_ascii=False,
            indent=2,
        )
        + "\n",
        encoding="utf-8",
    )
    print(args.output_text)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
