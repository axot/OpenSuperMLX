#!/bin/bash
# Writes a single-item Sparkle appcast for one release to stdout.
set -euo pipefail
export LC_ALL=C

if [[ "$#" -ne 7 ]]; then
    echo "usage: make-appcast.sh <version> <build> <minimum-system> <download-url> <ed-signature> <length> <notes-file>" >&2
    exit 64
fi

version="$1"
build="$2"
minimum_system="$3"
download_url="$4"
ed_signature="$5"
length="$6"
notes_file="$7"

escape_xml() { printf '%s' "$1" | sed -e 's/&/\&amp;/g' -e 's/</\&lt;/g' -e 's/>/\&gt;/g' -e 's/"/\&quot;/g'; }

notes="$(cat "$notes_file")"
# A CDATA section cannot contain "]]>", so split it across two sections.
notes_cdata="${notes//]]>/]]]]><![CDATA[>}"

cat <<APPCAST
<?xml version="1.0" encoding="utf-8"?>
<rss version="2.0" xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle">
  <channel>
    <title>OpenSuperMLX</title>
    <item>
      <title>$(escape_xml "$version")</title>
      <pubDate>$(date -u '+%a, %d %b %Y %H:%M:%S +0000')</pubDate>
      <sparkle:version>$(escape_xml "$build")</sparkle:version>
      <sparkle:shortVersionString>$(escape_xml "$version")</sparkle:shortVersionString>
      <sparkle:minimumSystemVersion>$(escape_xml "$minimum_system")</sparkle:minimumSystemVersion>
      <description sparkle:format="markdown"><![CDATA[${notes_cdata}]]></description>
      <enclosure url="$(escape_xml "$download_url")" length="$(escape_xml "$length")" type="application/octet-stream" sparkle:edSignature="$(escape_xml "$ed_signature")"/>
    </item>
  </channel>
</rss>
APPCAST
