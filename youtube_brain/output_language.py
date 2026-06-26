from __future__ import annotations


DEFAULT_OUTPUT_LANGUAGE = "English"
MAX_OUTPUT_LANGUAGE_LENGTH = 60


def normalize_output_language(value: str | None) -> str:
    """Clean a user-provided output-language label.

    Collapses whitespace/newlines, trims, caps the length, and falls back to
    the default when empty. The value is inserted verbatim into the prompt, so
    keep it to a short single line.
    """
    if value is None:
        return DEFAULT_OUTPUT_LANGUAGE
    cleaned = " ".join(str(value).split())
    if not cleaned:
        return DEFAULT_OUTPUT_LANGUAGE
    if len(cleaned) > MAX_OUTPUT_LANGUAGE_LENGTH:
        cleaned = cleaned[:MAX_OUTPUT_LANGUAGE_LENGTH].rstrip()
    return cleaned
