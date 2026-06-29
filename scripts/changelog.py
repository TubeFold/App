#!/usr/bin/env python3
"""Extract a CHANGELOG.md section and embed it into the Sparkle appcast.

Single source of truth for release notes: each released version has a
`## [X.Y] - DATE` section in CHANGELOG.md. That section's body is reused two
ways at release time:

  * `section`  prints the Markdown body (for `gh release create --notes-file`).
  * `inject`   inserts it as a Markdown `<description>` into the generated
               appcast item, so Sparkle shows it in the update dialog.
               Sparkle 2.9+ renders Markdown when the description carries
               `sparkle:format="markdown"`.

Both subcommands accept a bare or `v`-prefixed version. `section` and `inject`
exit 1 (not a hard error) when no section matches the version, so callers can
treat "no notes yet" as a soft, log-and-continue condition.

Usage:
  changelog.py section --version 0.6 [--changelog PATH]
  changelog.py inject  --version 0.6 [--changelog PATH] APPCAST_XML
"""
from __future__ import annotations

import argparse
import re
import sys
from pathlib import Path

_REPO_ROOT = Path(__file__).resolve().parent.parent
_DEFAULT_CHANGELOG = _REPO_ROOT / "CHANGELOG.md"

# A whole version-heading line: "## [0.6] - 2026-06-29", "## [0.6]", "## 0.6".
# The trailing `[^\n]*\n?` consumes the rest of the line (e.g. " - DATE") so the
# date never leaks into the captured body.
_HEADING = re.compile(r"^##\s+\[?(?P<version>[^\]\s]+)\]?[^\n]*\n?", re.MULTILINE)


def _normalize(version: str) -> str:
    return version[1:] if version.startswith("v") else version


def extract_section(changelog_text: str, version: str) -> str | None:
    """Return the trimmed Markdown body under `## [version]`, or None."""
    want = _normalize(version)
    matches = list(_HEADING.finditer(changelog_text))
    for i, m in enumerate(matches):
        if _normalize(m.group("version")) != want:
            continue
        body_start = m.end()
        body_end = matches[i + 1].start() if i + 1 < len(matches) else len(changelog_text)
        body = changelog_text[body_start:body_end].strip()
        return body or None
    return None


def _cmd_section(args: argparse.Namespace) -> int:
    text = Path(args.changelog).read_text(encoding="utf-8")
    body = extract_section(text, args.version)
    if body is None:
        print(f"changelog.py: no section for {args.version!r} in {args.changelog}",
              file=sys.stderr)
        return 1
    print(body)
    return 0


def _inject_description(appcast_xml: str, version: str, body: str) -> tuple[str, int]:
    """Insert <description> into every <item> whose shortVersionString matches.

    Returns (new_xml, count_injected). Existing <description> blocks in matching
    items are replaced, so re-running is idempotent.
    """
    want = _normalize(version)
    # CDATA can't contain "]]>"; split it the standard way if it ever does.
    safe = body.replace("]]>", "]]]]><![CDATA[>")
    injected = 0

    def repl_item(item_match: re.Match[str]) -> str:
        nonlocal injected
        item = item_match.group(0)
        sv = re.search(
            r"<sparkle:shortVersionString>\s*([^<]+?)\s*</sparkle:shortVersionString>",
            item,
        )
        if not sv or _normalize(sv.group(1).strip()) != want:
            return item
        # Remove any prior <description> so the operation is idempotent.
        item = re.sub(r"\s*<description>.*?</description>", "", item, flags=re.DOTALL)
        # Indent to match the <title> line, then insert right after it.
        title = re.search(r"^([ \t]*)<title>.*?</title>[ \t]*\n", item, flags=re.MULTILINE)
        indent = title.group(1) if title else "            "
        desc = f'{indent}<description sparkle:format="markdown"><![CDATA[\n{safe}\n]]></description>\n'
        if title:
            item = item[: title.end()] + desc + item[title.end():]
        else:  # no <title>: drop it right after <item>
            item = re.sub(r"(<item>\s*\n)", r"\1" + desc, item, count=1)
        injected += 1
        return item

    new_xml = re.sub(r"<item>.*?</item>", repl_item, appcast_xml, flags=re.DOTALL)
    return new_xml, injected


def _cmd_inject(args: argparse.Namespace) -> int:
    text = Path(args.changelog).read_text(encoding="utf-8")
    body = extract_section(text, args.version)
    if body is None:
        print(f"changelog.py: no section for {args.version!r} — appcast left without notes",
              file=sys.stderr)
        return 1
    appcast = Path(args.appcast)
    new_xml, count = _inject_description(appcast.read_text(encoding="utf-8"),
                                         args.version, body)
    if count == 0:
        print(f"changelog.py: no appcast <item> matched version {args.version!r}",
              file=sys.stderr)
        return 2
    appcast.write_text(new_xml, encoding="utf-8")
    print(f"changelog.py: embedded release notes for {args.version} "
          f"into {count} appcast item(s).")
    return 0


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    sub = parser.add_subparsers(dest="command", required=True)

    p_section = sub.add_parser("section", help="print a version's Markdown body")
    p_section.add_argument("--version", required=True)
    p_section.add_argument("--changelog", default=str(_DEFAULT_CHANGELOG))
    p_section.set_defaults(func=_cmd_section)

    p_inject = sub.add_parser("inject", help="embed a version's notes into an appcast")
    p_inject.add_argument("--version", required=True)
    p_inject.add_argument("--changelog", default=str(_DEFAULT_CHANGELOG))
    p_inject.add_argument("appcast")
    p_inject.set_defaults(func=_cmd_inject)

    args = parser.parse_args(argv)
    return args.func(args)


if __name__ == "__main__":
    raise SystemExit(main())
