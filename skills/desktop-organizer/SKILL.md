---
name: desktop-organizer
description: Organize loose Screenshot images and PDF files in a directory (typically ~/Desktop) into categorized folders named `YYYY-MM-DD_short-description`, grouped by filename prefix/theme using the earliest date in each group. Use when the user asks to "organize my Desktop", "clean up screenshots", "tidy these PDFs", or otherwise wants loose `.png`/`.pdf` files sorted into themed dated folders.
---

# Desktop Organizer

## Workflow

1. **Inventory** — List the target directory (default `~/Desktop`). Use `ls -la` and pipe long output to a file if needed; do not try to read 400+ lines inline.
2. **Group** — Cluster files by filename prefix/theme (see grouping rules below).
3. **Propose** — Show the user a table of proposed folders + file counts before moving anything. Ask the three standard questions.
4. **Confirm** — Wait for user answers.
5. **Execute** — Create folders, then `mv` files using globs.
6. **Verify** — Confirm no loose `.png` or `.pdf` remain; report counts per folder.
7. **Describe (optional)** — If the user wants untitled screenshots made scannable, rename them by content (see "Descriptive renaming" below). Offer this when an `uncategorized-screenshots` bucket ends up large.

## Grouping rules

**Folder name format:** `YYYY-MM-DD_short-description` where the date is the **earliest** date among files in the group (parsed from the filename, not mtime — filenames have reliable dates from screenshot/save time).

**Screenshots:** Group by the prefix before `_Screenshot` or `-Screenshot`. Examples:
- `aws_Screenshot 2026-01-20 at 7.36.58 PM.png` → group `aws`
- `cloud-armor_Screenshot 2025-12-10 at 5.15.50 PM.png` → group `cloud-armor`
- `2026-03-31_gcp-billing-Screenshot 2026-03-31 at 3.12.49 PM.png` → group `gcp-billing` (already-prefixed; treat the theme token as the group)
- `Screenshot 2026-03-19 at 3.53.56 PM.png` (no prefix) → goes to the uncategorized bucket

**PDFs:** PDFs rarely share a prefix. Cluster by topic from the filename — e.g., textbooks together, recurring receipts together, one-offs each in their own folder. When in doubt, give a one-off PDF its own folder rather than forcing it into a weak group.

**Singletons:** A single file still gets its own dated folder — that's the point of the organization.

## The three standard questions

Always ask before executing:

1. **Already-prefixed files** (e.g., `2026-04-01_rent-Screenshot…`) — fold into the matching theme folder, or leave alone?
2. **Untitled `Screenshot YYYY-MM-DD …` files** — bundle into one `YYYY-MM-DD_uncategorized-screenshots` folder, or split by month?
3. **Non-Screenshot PNGs** (e.g., `cursor-2025.png`, `care.png`, `www.example.com_*.png`) — include in screenshot folders, or skip?

For uncategorized PDFs that don't fit any theme, propose a `YYYY-MM-DD_uncategorized-pdfs` folder rather than leaving them loose.

## Execution gotchas

- **Use globs with `mv`, not fully-quoted filenames.** Filenames with spaces, em-dashes, parentheses, or non-ASCII cause intermittent "No such file or directory" errors even when correctly quoted. Globs (`mv prefix_*.png target/`) are reliable.
  - **Root cause for macOS screenshots:** the space before `AM`/`PM` is a **narrow no-break space (U+202F)**, not a regular space — bytes `M-bM-^@M-/` under `cat -A`. A quoted `"… 3.06.21 PM.png"` typed with a normal space will never match. Glob on the ASCII date/time digits instead: `mv $D/Screenshot*"2026-05-14 at 3.06.21"*.png "$D/newname.png"`. Verify the bytes with `ls <dir>/Screenshot*<time>*.png | cat -A` if `mv` mysteriously can't stat a file that `ls` clearly shows.
- **Don't rely on `cd` in compound commands.** Shell state does not persist between calls and a `cd x && mv …` chain may run the `mv` from the original directory (files "not found" though they exist). Use absolute paths throughout, or set `D="/abs/path"` once and prefix every operand with `$D/`.
- **`ls -1` may include `.` and `..`** when the user has `setopt GLOB_DOTS` or similar zsh config. For accurate counts use `ls -1A` or `find <dir> -maxdepth 1 -type f | wc -l`.
- **Chain moves with `&&`** so one failure stops the batch and surfaces the error rather than silently leaving files behind.
- **Files for non-glob-friendly groups** (single special-char filenames like `"Order received – Starting Arts.pdf"`) — quote and move individually; don't try to glob.
- **After moving, verify with `ls *.png` and `ls *.pdf`** in the source dir — should produce "no matches found" if complete.

## Descriptive renaming (optional)

When the user can't tell screenshots apart from `Screenshot YYYY-MM-DD …` names, **read each image** and rename it by content. This is a separate follow-up step, not part of the default move.

- **Target format:** `YYYY-MM-DD_HHMM_short-description.png`. The `HHMM` is the capture time in **24h** (convert AM/PM; `11.51.59 PM` → `2351`, `3.06.21 PM` → `1506`). Keeping the time prefix preserves chronological order within a day; ask the user if they'd rather have description-only.
- **Description:** 3–6 kebab-case tokens naming the app/site + subject, e.g. `amazon-usb-cable-order`, `gcloud-iam-security-policy-cve`, `disk-utility-sd-card-readonly`. Include a distinguishing detail when same-app shots would otherwise collide (`gym-membership-cart-deposit-492` vs `…-full-924`).
- **Read in batches** (e.g. 8 images per message) to keep context manageable; propose the full old→new mapping as a table and confirm before renaming.
- **Rename via globs** keyed on the ASCII date+time digits (see the U+202F gotcha above). A small helper keeps it readable:
  ```bash
  D="/abs/path/to/folder"
  ren() { mv $D/Screenshot*"$1"*.png "$D/$2"; }
  ren "2026-05-09 at 11.37.28" "2026-05-09_2337_amazon-usb-cable-order.png" && \
  ren "2026-05-09 at 11.51.59" "2026-05-09_2351_etsy-sticker-pack-order.png"
  ```
  For already-prefixed shots, include the prefix in the glob: `mv $D/claude-ai-Screenshot*"$1"*.png …`.
- After renaming, verify no `Screenshot*.png` remain in the folder.

## Example proposal table format

```
| Folder                              | Source files                       |
|-------------------------------------|------------------------------------|
| 2026-01-20_aws                      | aws_Screenshot*.png (13)           |
| 2026-02-05_dns                      | dns_Screenshot*.png (12)           |
| 2025-11-11_uncategorized-screenshots| Screenshot 2025-* + 2026-* (~100) |
```

Keep the table compact. For groups under 5 files, list filenames. For larger groups, show the glob and count.
