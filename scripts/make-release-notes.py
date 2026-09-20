#!/usr/bin/env python3
"""Render docs/releases/Limit-Bar-<version>.md into the compact HTML page that
Sparkle shows inside the update dialog.

The dialog is a small webview, so this page carries no site chrome, no web fonts
and no external requests - just the notes, styled for light and dark appearance.
Generating it from the Markdown keeps it identical to the GitHub release body.
"""

import html
import pathlib
import re
import sys

ROOT = pathlib.Path(__file__).resolve().parent.parent


def inline(text: str) -> str:
    """Escape, then re-apply the small subset of Markdown used in release notes."""
    out = html.escape(text)
    out = re.sub(r"`([^`]+)`", r"<code>\1</code>", out)
    out = re.sub(r"\*\*([^*]+)\*\*", r"<strong>\1</strong>", out)
    return out


def parse(markdown: str):
    title, lede, bullets, trailing = "", "", [], []
    seen_heading = False

    for raw in markdown.splitlines():
        line = raw.strip()
        if not line:
            continue
        if line.startswith("# "):
            title = line[2:].strip()
        elif line.startswith("## "):
            seen_heading = True
        elif line.startswith("- "):
            bullets.append(line[2:].strip())
        elif seen_heading and bullets:
            trailing.append(line)
        elif not seen_heading and not lede:
            lede = line

    return title, lede, bullets, trailing


TEMPLATE = """<!doctype html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>{title_attr}</title>
<style>
  :root {{
    color-scheme: light dark;
    --ink: #14162b;
    --muted: #4b5070;
    --soft: #6d7294;
    --rule: rgba(28, 32, 74, 0.12);
    --chip: rgba(28, 32, 74, 0.06);
    --page: #ffffff;
  }}
  @media (prefers-color-scheme: dark) {{
    :root {{
      --ink: #f3f5fa;
      --muted: #b6bbc9;
      --soft: #868c9b;
      --rule: rgba(255, 255, 255, 0.12);
      --chip: rgba(255, 255, 255, 0.08);
      --page: #1e2027;
    }}
  }}
  * {{ box-sizing: border-box; }}
  body {{
    margin: 0;
    padding: 16px 18px 20px;
    background: var(--page);
    color: var(--ink);
    font: 13px/1.5 -apple-system, BlinkMacSystemFont, "SF Pro Text", system-ui, sans-serif;
    -webkit-font-smoothing: antialiased;
  }}
  .kicker {{
    display: flex;
    align-items: center;
    gap: 7px;
    margin-bottom: 7px;
    color: var(--soft);
    font-size: 10px;
    font-weight: 600;
    letter-spacing: 0.1em;
    text-transform: uppercase;
  }}
  .kicker::before {{
    content: "";
    width: 16px;
    height: 3px;
    border-radius: 999px;
    background: linear-gradient(90deg, #12b5a6, #6f5ce0);
  }}
  h1 {{
    margin: 0 0 5px;
    font-size: 19px;
    font-weight: 600;
    letter-spacing: -0.02em;
  }}
  .lede {{
    margin: 0 0 14px;
    color: var(--muted);
    font-size: 13px;
  }}
  ul {{
    margin: 0;
    padding: 0;
    list-style: none;
  }}
  li {{
    position: relative;
    padding-left: 17px;
    margin-bottom: 8px;
    color: var(--muted);
  }}
  li::before {{
    content: "";
    position: absolute;
    left: 1px;
    top: 7px;
    width: 6px;
    height: 6px;
    border-radius: 50%;
    background: linear-gradient(135deg, #12b5a6, #6f5ce0);
  }}
  li strong {{ color: var(--ink); font-weight: 600; }}
  code {{
    padding: 1px 5px;
    border-radius: 5px;
    background: var(--chip);
    font: 11.5px/1 ui-monospace, SFMono-Regular, Menlo, monospace;
  }}
  .meta {{
    margin: 14px 0 0;
    padding-top: 11px;
    border-top: 1px solid var(--rule);
    color: var(--soft);
    font-size: 11.5px;
  }}
</style>
</head>
<body>
<p class="kicker">Release notes</p>
<h1>{title}</h1>
{lede}<ul>
{items}
</ul>
{meta}</body>
</html>
"""


def render(version: str) -> str:
    source = ROOT / "docs" / "releases" / f"Limit-Bar-{version}.md"
    if not source.is_file():
        raise SystemExit(f"Missing release notes source: {source}")

    title, lede, bullets, trailing = parse(source.read_text())
    if not bullets:
        raise SystemExit(f"No bullet points found in {source}")

    return TEMPLATE.format(
        title_attr=html.escape(title or f"Limit Bar {version}"),
        title=inline(title or f"Limit Bar {version}"),
        lede=f'<p class="lede">{inline(lede)}</p>\n' if lede else "",
        items="\n".join(f"  <li>{inline(b)}</li>" for b in bullets),
        meta=f'<p class="meta">{inline(" ".join(trailing))}</p>\n' if trailing else "",
    )


def main() -> None:
    if len(sys.argv) != 2:
        raise SystemExit("Usage: make-release-notes.py <marketing-version>")

    version = sys.argv[1]
    destination = ROOT / "Landing" / "releases" / f"Limit-Bar-{version}.html"
    destination.write_text(render(version))
    print(f"Wrote {destination.relative_to(ROOT)}")


if __name__ == "__main__":
    main()
