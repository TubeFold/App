#!/usr/bin/env python3
from __future__ import annotations

import argparse
import json
from pathlib import Path

from youtube_summary_lib import metadata_fields, render_template


def main() -> int:
    parser = argparse.ArgumentParser(description="Render a youtube-summary prompt template")
    parser.add_argument("template_file", type=Path)
    parser.add_argument("metadata_json", type=Path)
    parser.add_argument("transcript_file", type=Path)
    parser.add_argument("transcript_language")
    parser.add_argument("output_file", type=Path)
    parser.add_argument("--fallback-url", default="")
    args = parser.parse_args()

    metadata = json.loads(args.metadata_json.read_text(encoding="utf-8"))
    fields = metadata_fields(metadata, args.fallback_url or metadata.get("webpage_url") or "")
    transcript = args.transcript_file.read_text(encoding="utf-8")
    template = args.template_file.read_text(encoding="utf-8")

    prompt = render_template(
        template,
        {
            "TITLE": fields["title"],
            "URL": fields["url"],
            "CHANNEL": fields["channel"],
            "DURATION": fields["duration"],
            "SUBTITLE_LANGUAGE": args.transcript_language,
            "TRANSCRIPT_LANGUAGE": args.transcript_language,
            "TRANSCRIPT": transcript.rstrip(),
        },
    )
    args.output_file.write_text(prompt.rstrip() + "\n", encoding="utf-8")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
