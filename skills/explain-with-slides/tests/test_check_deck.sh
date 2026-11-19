#!/usr/bin/env bash
set -euo pipefail
# Zero-token checks for explain-with-slides: the docs, the template, the worked
# example, and check_deck.py's verdicts on small decks that break each rule.
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SKILL_DIR="$(cd "$HERE/.." && pwd)"
CHECK="$SKILL_DIR/scripts/check_deck.py"
TEMPLATE="$SKILL_DIR/assets/deck-template.html"
EXAMPLE="$SKILL_DIR/references/example-bloom-filter.html"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
pass=0; fail=0
ok()  { pass=$((pass+1)); }
bad() { fail=$((fail+1)); echo "FAIL: $1" >&2; }

# 1: the skill's files exist and name each other correctly.
grep -q "^name: explain-with-slides$" "$SKILL_DIR/SKILL.md"  && ok || bad "frontmatter name wrong"
for f in assets/deck-template.html references/example-bloom-filter.html \
         references/slide-patterns.md scripts/check_deck.py; do
  [ -f "$SKILL_DIR/$f" ] && ok || bad "$f missing"
  grep -q "$f" "$SKILL_DIR/SKILL.md" && ok || bad "SKILL.md does not mention $f"
done

# 2: no em dashes in the prose files.
for f in SKILL.md references/slide-patterns.md; do
  ! grep -q "—" "$SKILL_DIR/$f" && ok || bad "$f contains an em dash"
done

# 3: the template is self-contained and keeps the shared design tokens.
! grep -Eqi '<script[^>]+src=|<link[^>]+href=|@import' "$TEMPLATE" && ok || bad "template loads an external resource"
for tok in "--ivory:   #FAF9F5" "--clay:    #D97757" "--olive:   #788C5D" "--rust:    #B04A3F"; do
  grep -qF -- "$tok" "$TEMPLATE" && ok || bad "template lost token $tok"
done

# 4: the worked example passes the checker with no warnings.
out="$(python3 "$CHECK" "$EXAMPLE")" && ok || bad "example fails check_deck.py: $out"
echo "$out" | grep -q "0 errors, 0 warnings" && ok || bad "example has warnings: $out"

# 5: the example is the template plus slides (same CSS and script).
sed -n '/<style>/,/<\/style>/p' "$TEMPLATE" > "$TMP/t.css"
sed -n '/<style>/,/<\/style>/p' "$EXAMPLE"  > "$TMP/e.css"
cmp -s "$TMP/t.css" "$TMP/e.css" && ok || bad "example CSS drifted from the template"
sed -n '/^<script>/,/^<\/script>/p' "$TEMPLATE" > "$TMP/t.js"
sed -n '/^<script>/,/^<\/script>/p' "$EXAMPLE"  > "$TMP/e.js"
cmp -s "$TMP/t.js" "$TMP/e.js" && ok || bad "example script drifted from the template"

# 5b: the deck reads at phone width, works from the keyboard and announces
# slide changes. The example shares this CSS and script through check 5.
grep -q '@media screen and (max-width: 640px)' "$TEMPLATE" && ok || bad "template has no screen-only phone-width layout"
grep -q '\.btn:focus-visible { outline: 2px solid' "$TEMPLATE" && ok || bad "focus ring missing or styled like hover"
! grep -q '\.disabled = ' "$TEMPLATE" && ok || bad "arrows set disabled, which drops keyboard focus at the ends"
grep -q 'inner.scrollBy(' "$TEMPLATE" && ok || bad "Up / Down never scroll the notes pane"
grep -q 'overflow-wrap: break-word' "$TEMPLATE" && ok || bad "a long unbreakable string can widen the page"
grep -q 'prefers-reduced-motion: reduce' "$TEMPLATE" && ok || bad "motion ignores prefers-reduced-motion"
for f in "$TEMPLATE" "$EXAMPLE"; do
  grep -q 'id="counter" aria-live="polite"' "$f" && ok || bad "$f: slide counter is not a live region"
  ! grep -Eq '<title>(<!--|.*·)' "$f" && ok || bad "$f: <title> holds more than a short name"
done
grep -q '<html lang' "$SKILL_DIR/SKILL.md" && ok || bad "SKILL.md does not say to set <html lang>"

# Decks that break one rule each. $1 = file, $2 = slide body.
deck() {
  { echo '<!doctype html><html><body><main>'; cat; echo '</main></body></html>'; } > "$1"
}
NOTES="$(printf 'word %.0s' $(seq 1 200))"
good_slide() {
  printf '<section class="slide"><div class="stage"><h2 class="claim">%s</h2>' "$1"
  printf '<svg class="fig" viewBox="0 0 960 440"><text>box</text></svg></div>'
  printf '<aside class="notes"><div class="notes-inner"><p>%s</p></div></aside></section>\n' "$NOTES"
}

# 6: missing notes is an error.
{ good_slide "A claim"
  echo '<section class="slide"><div class="stage"><h2 class="claim">B</h2><svg class="fig"></svg></div></section>'
} | deck "$TMP/no-notes.html"
if python3 "$CHECK" "$TMP/no-notes.html" > "$TMP/out" ; then bad "missing notes passed"; else ok; fi
grep -q "slide 2: no notes" "$TMP/out" && ok || bad "missing notes not reported"

# 7: an external script is an error.
{ good_slide "A claim"; echo '<script src="https://cdn.example.com/x.js"></script>'; } | deck "$TMP/ext.html"
if python3 "$CHECK" "$TMP/ext.html" > "$TMP/out"; then bad "external script passed"; else ok; fi
grep -q "external resource" "$TMP/out" && ok || bad "external script not reported"

# 8: a slide without a figure is an error.
printf '<section class="slide"><div class="stage"><h2 class="claim">A</h2></div><aside class="notes"><div class="notes-inner"><p>%s</p></div></aside></section>\n' "$NOTES" \
  | deck "$TMP/no-fig.html"
if python3 "$CHECK" "$TMP/no-fig.html" > "$TMP/out"; then bad "missing figure passed"; else ok; fi
grep -q "no figure" "$TMP/out" && ok || bad "missing figure not reported"

# 9: prose on the slide, short notes and an orphan marker are warnings only.
cat <<HTML | deck "$TMP/style.html"
<section class="slide"><div class="stage"><h2 class="claim">A claim</h2>
<p>A paragraph that belongs in the notes.</p>
<svg class="fig"><g class="mk"><circle/><text>1</text></g></svg></div>
<aside class="notes"><div class="notes-inner"><p>Too short.</p></div></aside></section>
HTML
python3 "$CHECK" "$TMP/style.html" > "$TMP/out" && ok || bad "style-only problems failed the deck"
grep -q "paragraphs or lists on the slide" "$TMP/out" && ok || bad "slide prose not warned"
grep -q "notes are about" "$TMP/out"                  && ok || bad "short notes not warned"
grep -q "marker 1 is never referenced" "$TMP/out"     && ok || bad "orphan marker not warned"

# 10: Japanese notes are counted by characters, not spaces.
JA="$(printf 'これは日本語のノートです。%.0s' $(seq 1 40))"
printf '<section class="slide"><div class="stage"><h2 class="claim">結論を述べるタイトル</h2><svg class="fig"></svg></div><aside class="notes"><div class="notes-inner"><p>%s</p></div></aside></section>\n' "$JA" \
  | deck "$TMP/ja.html"
python3 "$CHECK" "$TMP/ja.html" > "$TMP/out" && ok || bad "Japanese deck failed"
! grep -q "notes are about" "$TMP/out" && ok || bad "Japanese notes miscounted: $(cat "$TMP/out")"

echo "explain-with-slides: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
