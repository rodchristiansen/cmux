#!/usr/bin/env python3

import argparse
import html
import pathlib
import re
import sys


CHANGELOG_HEADER_RE = re.compile(r"^## \[([^\]]+)\] - .*$", re.MULTILINE)
SECTION_HEADER_RE = re.compile(r"^###\s+(.*\S)\s*$")
MARKDOWN_LINK_RE = re.compile(r"\[([^\]]+)\]\([^)]+\)")
ITALIC_RE = re.compile(r"(?<!\*)\*([^*\n]+)\*(?!\*)")
UNDERSCORE_RE = re.compile(r"(?<!_)_([^_\n]+)_(?!_)")


def normalize_tag(tag: str) -> str:
    return tag[1:] if tag.startswith("v") else tag


def strip_markdown(text: str) -> str:
    text = MARKDOWN_LINK_RE.sub(r"\1", text)
    text = text.replace("`", "")
    text = text.replace("**", "")
    text = text.replace("__", "")
    text = ITALIC_RE.sub(r"\1", text)
    text = UNDERSCORE_RE.sub(r"\1", text)
    text = html.unescape(text)
    return re.sub(r"\s+", " ", text).strip()


def extract_release_section(changelog: str, tag: str) -> str:
    normalized_tag = normalize_tag(tag)
    matches = list(CHANGELOG_HEADER_RE.finditer(changelog))

    for index, match in enumerate(matches):
        if normalize_tag(match.group(1)) != normalized_tag:
            continue

        start = match.end()
        end = matches[index + 1].start() if index + 1 < len(matches) else len(changelog)
        return changelog[start:end].strip()

    return ""


def format_release_notes(section: str) -> str:
    if not section:
        return ""

    formatted_lines: list[str] = []

    for raw_line in section.splitlines():
        line = raw_line.strip()

        if not line:
            if formatted_lines and formatted_lines[-1] != "":
                formatted_lines.append("")
            continue

        section_match = SECTION_HEADER_RE.match(line)
        if section_match:
            heading = strip_markdown(section_match.group(1))
            if heading:
                if formatted_lines and formatted_lines[-1] != "":
                    formatted_lines.append("")
                formatted_lines.append(heading)
            continue

        if line.startswith("- "):
            bullet = strip_markdown(line[2:])
            if bullet:
                formatted_lines.append(f"• {bullet}")
            continue

        paragraph = strip_markdown(line)
        if paragraph:
            formatted_lines.append(paragraph)

    while formatted_lines and formatted_lines[0] == "":
        formatted_lines.pop(0)
    while formatted_lines and formatted_lines[-1] == "":
        formatted_lines.pop()

    return "\n".join(formatted_lines)


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description="Extract plain-text appcast release notes from CHANGELOG.md."
    )
    parser.add_argument("--tag", required=True, help="Release tag, for example v0.62.2")
    parser.add_argument(
        "--changelog",
        default="CHANGELOG.md",
        help="Path to the changelog file. Defaults to CHANGELOG.md",
    )
    return parser.parse_args()


def main() -> int:
    args = parse_args()
    changelog_path = pathlib.Path(args.changelog)

    if not changelog_path.is_file():
        return 0

    changelog = changelog_path.read_text(encoding="utf-8")
    section = extract_release_section(changelog, args.tag)
    release_notes = format_release_notes(section)

    if release_notes:
        sys.stdout.write(release_notes)

    return 0


if __name__ == "__main__":
    raise SystemExit(main())
