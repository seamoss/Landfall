#!/usr/bin/env python3
"""Add a release to appcast.xml (Sparkle's update feed). Newest first; keeps the last 15 releases.

usage: appcast.py --version 0.6.0 --build 202610131400 --url <dmg url> --signature 'sparkle:edSignature="…" length="…"'
                  --notes CHANGELOG-section.md --notes-link <release page> [--feed appcast.xml]
"""
import argparse, html, re, email.utils, pathlib, time

EMPTY = """<?xml version="1.0" encoding="utf-8"?>
<rss version="2.0" xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle" xmlns:dc="http://purl.org/dc/elements/1.1/">
  <channel>
    <title>Landfall</title>
    <link>https://github.com/seamoss/Landfall</link>
    <description>Landfall updates</description>
    <language>en</language>
  </channel>
</rss>
"""

def md_to_html(md: str) -> str:
    """Just enough Markdown for CHANGELOG sections: ### headings, - bullets, **bold**, `code`, [links](url)."""
    out, in_list = [], False
    def inline(s):
        s = html.escape(s)
        s = re.sub(r"\*\*(.+?)\*\*", r"<b>\1</b>", s)
        s = re.sub(r"`(.+?)`", r"<code>\1</code>", s)
        return re.sub(r"\[(.+?)\]\((https?://[^)]+)\)", r'<a href="\2">\1</a>', s)
    for line in md.splitlines():
        if line.startswith("- "):
            if not in_list: out.append("<ul>"); in_list = True
            out.append(f"<li>{inline(line[2:])}</li>")
            continue
        if in_list: out.append("</ul>"); in_list = False
        if line.startswith("### "): out.append(f"<h3>{inline(line[4:])}</h3>")
        elif line.strip(): out.append(f"<p>{inline(line)}</p>")
    if in_list: out.append("</ul>")
    return "\n".join(out)

a = argparse.ArgumentParser()
for k in ("version", "build", "url", "signature", "notes", "notes-link"): a.add_argument(f"--{k}", required=True)
a.add_argument("--feed", default="appcast.xml")
args = a.parse_args()

feed = pathlib.Path(args.feed)
text = feed.read_text() if feed.exists() else EMPTY
if f"<sparkle:shortVersionString>{args.version}</sparkle:shortVersionString>" in text:
    raise SystemExit(f"appcast already has {args.version}")
sig = args.signature.strip()
if not re.fullmatch(r'sparkle:edSignature="[^"]+" length="\d+"', sig):
    raise SystemExit(f"unexpected sign_update output: {sig!r}")

item = f"""    <item>
      <title>Landfall {args.version}</title>
      <pubDate>{email.utils.formatdate(time.time())}</pubDate>
      <sparkle:version>{args.build}</sparkle:version>
      <sparkle:shortVersionString>{args.version}</sparkle:shortVersionString>
      <sparkle:minimumSystemVersion>14.0</sparkle:minimumSystemVersion>
      <sparkle:fullReleaseNotesLink>{html.escape(args.notes_link)}</sparkle:fullReleaseNotesLink>
      <description><![CDATA[
{md_to_html(pathlib.Path(args.notes).read_text())}
      ]]></description>
      <enclosure url="{html.escape(args.url)}" type="application/octet-stream" {sig}/>
    </item>
"""
anchor = "    <item>" if "    <item>" in text else "  </channel>"
text = text.replace(anchor, item + anchor, 1)
items = re.findall(r"    <item>.*?    </item>\n", text, flags=re.S)
for old in items[15:]:
    text = text.replace(old, "")
feed.write_text(text)
print(f"appcast: added {args.version} (build {args.build})")
