# Autoslip-Howm

![Version](https://img.shields.io/static/v1?label=autoslip-howm&message=0.1.0&color=brightcolor)
[![License: GPL v3](https://img.shields.io/badge/License-GPLv3-blue.svg)](https://www.gnu.org/licenses/gpl-3.0)
[![Emacs](https://img.shields.io/badge/Emacs-27.1+-blueviolet.svg)](https://www.gnu.org/software/emacs/)
[![howm](https://img.shields.io/badge/howm-1.4.x-green.svg)](https://kaorahi.github.io/howm/)

Automatic folgezettel (computer-compatible Luhmann-style) bidirectional link generation for [howm](https://kaorahi.github.io/howm/). 
Howm is similar to the Emacs package Denote in that it is file-based and does not depend on a database. 
Howm inserts a unique identifier in each note, providing a persistent address that survives changes to the note's title.
This supports moving subtrees of notes to a new parent note.

Howm differs from Denote in that it also supports smart time management through a simpler, more humane to-do list system than org-agenda.
Howm was started in 2002, so it predates Denote by two decades and is even older than org-mode.
It can accommodate org-mode, markdown, and txt files. 
We use org-mode in this package because it is widely used by Emacs users.

We provide support for importing Markdown notes from Obsidian that already have Folgezettel.
This support includes the ability to select hundreds of files in the Mac Finder.
We plan to add support for importing notes from org-roam and Denote.

This package brings the same workflow as [autoslip-roam](https://github.com/MooersLab/autoslip-roam) to Howm users. 
It uses the folgezettel index in a note's title to determine parent-child relationships, 
then writes goto-links and come-from anchors so that howm's keyword search retrieves both directions of every relationship.
It overrides Howm's default numeric filename format, which is similar to Denotes.

The folgezettel index appears at the start of the title and the filename. 
The package is compatible with printing notes for storage in a paper-based zettelkasten.

## Why a port

Howm has no central database, no node IDs, and no `org-roam-capture-` hook. 
Notes are plain files in a directory tree, and links are wiki keywords. 
*autoslip-howm* replaces the org-roam-specific machinery in *autoslip-roam* with a directory scan, 
a stable wiki-keyword scheme, and a `howm-create-file-hook` integration.

## What problems are addressed

The two problems are unchanged from the autoslip-roam README:

1. True automation of bidirectional linking, so that you do not have to add the inverse link by hand.
2. A bridge to a paper-based zettelkasten, because the folgezettel address is also the storage order.

The full motivation for both is in the autoslip-roam README; everything in those sections applies here.

## Identity model

Each note carries a self-anchor on a dedicated line:

```
<<< autoslip:1.2a:k7n3p3qr
```

The string after the namespace is the visible folgezettel address. 
The string after the second colon is a UID minted at note creation. 
Inbound links are written with the goto marker:

```
>>> autoslip:1.2a:k7n3p3qr
```

The UID does the load-bearing work. 
The address segment can be rewritten on reparent. 
Inbound goto-links remain valid because their UIDs match.

## Title model

The title is the first non-empty line of the file. 
Common howm and org markers (`#+TITLE:`, `= `, `, M `, `, `) are stripped before the folgezettel is extracted. 
Any non-empty first line is acceptable.

## File-naming convention

```
ADDRESS-SLUG.EXT
```

Examples: `1.2a-crystal-symmetry.org`, `1.2a-crystal-symmetry.txt`. 
The address comes first by user preference. 
The slug is generated from the title at the time of creation. 
The extension is governed by `autoslip-howm-default-extension` (default `.org`).

## Installation

Manual installation:

```bash
git clone https://github.com/MooersLab/autoslip-howm.git
```

```elisp
(add-to-list 'load-path "/path/to/autoslip-howm")
(require 'autoslip-howm)
(setq autoslip-howm-directory "~/Howm/")
(autoslip-howm-mode 1)
```

With use-package:

```elisp
(use-package autoslip-howm
  :load-path "/path/to/autoslip-howm"
  :after howm
  :custom
  (autoslip-howm-directory "~/howm/")
  (autoslip-howm-default-extension ".org")
  :config
  (autoslip-howm-mode 1))
```

## Quick start

Create a root note in Howm by entering `C-c ; c`. The first non-empty line is the title:

```
1. Crystallography
```

Save the file. The package writes a self-anchor:

```
1. Crystallography
<<< autoslip:1.:k7n3p3qr
```

The package also offers a one-step alternative that prompts for the address and the title, creates the file with a leading-address filename, writes the self-anchor, and visits the new buffer:

```
M-x autoslip-howm-create-note
```

This is the right command for any note whose address you already know, and especially for minting roots like `1.`, `2.`, `3.`.

Create a child:

```
M-x autoslip-howm-insert-next-child
```

The package suggests `1.1`, prompts for a title, writes the new file, and inserts:

- a `>>> autoslip:1.:k7n3p3qr` goto-link in the child under a `Parent Note` heading,
- a `>>> autoslip:1.1:r2x9b7vt` goto-link in the parent under a `Child Notes` heading.

## Folgezettel address format

The format is identical to autoslip-roam.

| Address | Description |
|---------|-------------|
| `1.` | Root note |
| `1.2` | Second subtopic of note 1 |
| `1.2a` | First letter branch of 1.2 |
| `1.2aa` | 27th child of 1.2 |
| `1.2a3` | Third numeric child of 1.2a |

Rules: start with a number; root form is `N.`; only one period; numbers and letters alternate after the period; lowercase letters only; extended alphabet `aa, ab, ..., zz, aaa` after `z`.

The filenames organize the notes in file listings.
This display shows the relationship between notes.
This really negates the need for a graphical display of the knowledge graph.

## Storage modes

- `headings` (default) writes visible `Parent Note` and `Child Notes` sections in the body. In `.org` files, the heading uses stars; in plain-text files, the heading uses the configurable `autoslip-howm-text-heading-format`.
- `headers` writes a top-of-file header block of the form `@FZ_PARENT: autoslip:1.:k7n3p3qr` and `@FZ_CHILDREN: autoslip:1.2:r2x9b7vt, autoslip:1.3:m4q1d9s2`. Body stays clean.

Switch modes with `(setq autoslip-howm-link-storage 'headers)`.

## Index of Indices

The roots of a folgezettel zettelkasten are the small set of major topics that organize everything else. 
In autoslip-howm, those roots have addresses like `1.`, `2.`, `3.`. 
Each root anchors a chain of thought that grows downward through child notes such as `1.2`, `1.2a`, `1.2a3`. 
The `00. Index of Indices` note is a flat catalog of every root, and it lives at a numerically lower address than `1.`, so it sorts to the top of the tree view and to the top of any directory listing.

The package treats every `N.` address as a root with no parent. 
The double-zero in `00.` is a sibling root, not a parent of `1.`, `2.`, and the rest. 
This is the right semantics, because the index of indices is a pointer page, not a parent. 
The single-digit form `0.` would also sort early, but `00` reads as an obvious meta-marker.

`00.` is not a node in the knowledge graph; instead, the root nodes form a multiple-headed graph with parallel chains of thought cross-linked together with connections between notes in separate chains of thought.

### Workflow

Sit with a piece of paper or a whiteboard for an hour and list the major areas of knowledge you want this zettelkasten to cover. 
Pick between five and fifty. 
Fewer than five is too coarse.
Number the list from 1.

Create each root before you create the index, because the index has to reference each root's stable wiki keyword:

```
M-x autoslip-howm-create-note RET 1. RET Crystallography RET
M-x autoslip-howm-create-note RET 2. RET Statistical methods RET
M-x autoslip-howm-create-note RET 3. RET Computational tools RET
```

With the roots in place, create the index with one command:

```
M-x autoslip-howm-open-index
```

If the file does not yet exist, the command seeds it with a title line, a self-anchor for `00.`, a top-level heading, and a sorted list of every root. 
Subsequent calls open the existing file. 
Add a one-sentence annotation under each root entry. 
The annotation is the part that earns its keep over time, because the link list itself is mechanical.

When you mint a new root later, refresh the auto-block in `00.` with:

```
M-x autoslip-howm-insert-root-list
```

The command writes a fresh, folgezettel-sorted heading block at point. 
It is non-destructive; you delete the old block by hand before calling it, or place it under a dedicated heading you keep clearing.

### Anti-patterns

Two patterns are worth naming as things to avoid. The first is treating `00.` as a parent of the real roots and giving them addresses like `00.1`, `00.2`, `00.3`. 
This collapses the topology and breaks the parent-walk semantics for any chain of thought. Keep the real roots at `1.`, `2.`, `3.`.

The second is using `00.` as the only navigation surface. The tree view, `M-x autoslip-howm-show-tree`, shows the full vault grouped under each root and is more useful for browsing. 
The index is the table of contents. 
The tree view is the table of contents plus every page number. 
Use both.

### Setup checklist

- [ ] List of major topics drafted on paper
- [ ] Each major topic given a root address (`1.`, `2.`, ...)
- [ ] Each root note created via `autoslip-howm-create-note`
- [ ] `M-x autoslip-howm-open-index` run once
- [ ] Each root has a one-sentence annotation in `00.`
- [ ] `C-c m i` bound to `autoslip-howm-open-index`
- [ ] `C-c m I` bound to `autoslip-howm-insert-root-list`
- [ ] Tree view sanity-checked with `M-x autoslip-howm-show-tree`

## Hub indexes and topic indexes

The folgezettel numbering system organizes a chain of thought along one vertical axis, but related notes often live in parallel chains. autoslip-howm offers two kinds of in-note index to address both shapes of relation. The two use distinguishable wrapper headings so a reader can tell at a glance which one they are looking at.

### Hub index (vertical, descent of one tier)

A hub index lists only the direct children of the current note. Use it at the top of a hub note, or at any branching point inside a chain of thought, when you want a one-screen overview of the immediate descendants without the rest of the subtree. Grandchildren and deeper descendants are intentionally omitted.

```
M-x autoslip-howm-insert-hub-index
```

The block is wrapped in a level-2 heading `Children of N.M`, where `N.M` is the current note's folgezettel. Each child becomes a level-3 heading, with a goto-link on the line below.

### Topic index (horizontal, across chains)

A topic index lists every note in the vault whose body matches a regular expression. Use it to surface cross-references that span chains of thought: notes about Bayesian methods that you wrote inside the protein-structure chain, the cryo-EM chain, and the statistics chain, all in one block.

```
M-x autoslip-howm-insert-topic-index RET symmetry RET
```

The block is wrapped in a level-2 heading `Topic Index: SEARCH-TERM`. Each matching note becomes a level-3 heading with a goto-link. The current note is excluded from its own topic index even when its body matches.

### Visual distinction

The wrapper headings are deliberately different:

```
** Children of 1.2a       <- hub index, vertical
** Topic Index: kinetics  <- topic index, horizontal
```

That way a reader scanning a hub note can tell at a glance which kind of index they are looking at, and what scope to expect.

### Suggested key bindings

```elisp
(define-key howm-mode-map (kbd "C-c m H") #'autoslip-howm-insert-hub-index)
(define-key howm-mode-map (kbd "C-c m T") #'autoslip-howm-insert-topic-index)
```

### Customization

```elisp
(setq autoslip-howm-hub-index-heading-format "Children of %s")
(setq autoslip-howm-topic-index-heading-format "Topic Index: %s")
```

Both formats receive a single argument (the folgezettel for the hub index, the search term for the topic index). Change them if you want a different banner shape, but keep the two formats distinguishable.

### Search backends

Topic-index search ships with three backends, selected by `autoslip-howm-search-backend`:

| Backend | Tool | Speed | Regex flavor | When to choose |
|---------|------|-------|--------------|----------------|
| `auto` (default) | best of the three | n/a | inherits | the right choice for almost everyone |
| `rg` | ripgrep | fastest | Rust regex (PCRE-like) | tens of thousands of notes |
| `grep` | GNU or BSD grep | fast | ERE | rg unavailable, large vault |
| `emacs` | in-Emacs scan | slow | Emacs regex | need `\b`, `\<`, `\>`, or other Emacs-specific syntax |

In `auto` mode the package picks the first available of `rg`, `grep`, and the in-Emacs scan, in that order. Install ripgrep with your package manager (`brew install ripgrep` or `apt install ripgrep`) for the fastest experience; for tens of thousands of notes the difference is roughly two orders of magnitude.

```elisp
;; Pin a backend if you prefer not to rely on auto-detection.
(setq autoslip-howm-search-backend 'rg)
;; Custom executable paths if needed.
(setq autoslip-howm-rg-program "/opt/homebrew/bin/rg")
(setq autoslip-howm-grep-program "/opt/homebrew/opt/grep/libexec/gnubin/grep")
```

Subprocess output is post-filtered against the cached note list, so any hits inside `.git`, backup files, or non-howm clutter under the howm directory are dropped automatically.

The regex flavor depends on the chosen backend. For literal words, character classes, anchors (`^`, `$`), alternation, and the common quantifiers, all three flavors behave identically. Word-boundary syntax differs: rg and the in-Emacs scan accept `\b`, but grep with `-E` does not. If you depend on `\b`, `\<`, `\>`, or other Emacs-specific syntax, pin the backend to `emacs`.

## Importing from Obsidian

If you already maintain a `00. Index of Indices` note in an Obsidian vault, the package can bootstrap a Howm zettelkasten from it in one step. The Obsidian file is expected to contain markdown links of the form `[N. Title](N.%20Title.md)`, with a `## Project Support` heading that splits a knowledge section from a project-management section. Project entries are renumbered on import to keep them visually separated from the knowledge roots.

```
M-x autoslip-howm-import-from-obsidian RET /path/to/00.-Index-of-Indices.md RET
```

For each entry in the markdown file, the package creates a Howm root note with the corresponding folgezettel address. Numbers in the project section are offset by `autoslip-howm-obsidian-project-offset` (default 400), so Obsidian's `100. Research programs` becomes Howm's `500. Research programs`. The default value matches the recommended layout of keeping knowledge roots in `1.` through `99.` and project-management roots from `500.` upward.

### Reconciliation

If a Howm `00.` index file already exists when you run the import, the command prompts:

```
An index already exists. Master list: [obsidian | howm | cancel]
```

For each Obsidian entry, the importer tries to reuse an existing file before minting a new one. The dispatch is:

1. **Address match.** A Howm note exists at the imported address. If its title already matches, the note is left alone. If the title differs and the master is Obsidian, the title line is rewritten. If the master is Howm, the title is preserved.
2. **Title match.** No note has that address, but a note with the same title (compared by slug after stripping any leading folgezettel) exists at a different address, or at no address at all. With Obsidian as master, the existing note is renumbered to the imported address: title line, self-anchor, inbound goto-links, and file name are all rewritten in place. With Howm as master, the existing note keeps its address and nothing new is created for that title.
3. **File on disk.** No address match and no title match in the cache, but the canonical destination file already exists on disk (a half-finished prior import, a file copied in from elsewhere, an empty stub). The importer adopts that file: it ensures the first non-empty line reads `ADDRESS TITLE` and that a self-anchor for the address is present, while leaving the rest of the body untouched.
4. **Create.** None of the above. A fresh root note is minted with the canonical filename and content.

The end-of-run message reports five counters so you can see what happened:

```
Imported 47 entries: 12 created, 3 renamed, 5 renumbered, 7 adopted, 20 unchanged (master: obsidian)
```

The `00.` file body is regenerated at the end so it lists every current root in folgezettel order. Hand-written annotations in the existing `00.` file are not preserved across regeneration. Copy them aside before importing if they matter.

### Customization

Two variables tune the parser:

```elisp
(setq autoslip-howm-obsidian-project-heading-regexp
      "^##[ \\t]+Project[ \\t]+Support[ \\t]*$")
(setq autoslip-howm-obsidian-project-offset 400)
```

Set the offset to `0` to import project numbers unchanged, or to a different value to land the project section at any base address you prefer.

## Importing children of a single parent from Obsidian

A separate command imports a markdown file that lists the **children** of one parent note. This is the workflow when you have an Obsidian note like `1. Crystallography.md` whose body is a bullet list of `[1.1 Introduction](1.1%20Introduction.md)`, `[[1.14 quantum crystallography]]`, etc. Both standard markdown links and Obsidian wikilinks are accepted.

```
M-x autoslip-howm-import-children-from-obsidian RET /path/to/1.\ Crystallography.md RET 1. RET
```

The two prompts are the markdown source and the parent's folgezettel address. When the current buffer is already a tracked howm note, that note's address is offered as the default parent, so you can press `RET` to accept.

For each child entry the same four-tier reconciliation applies (address match, title-slug match, file-on-disk, create). Entries whose address does not lie under the parent are skipped silently, so a `## Index of Indices or Master Node` block at the end of the file is harmless. After the dispatch, four things happen:

- Each child receives a backlink to the parent under the heading named by `autoslip-howm-backlink-heading` (default `Parent Note`), or in the parent property when `headers` storage is selected.
- The parent receives a forward link to each child under the heading named by `autoslip-howm-forward-link-heading` (default `Child Notes`). Each entry is a level-3 heading carrying the child's full title (address plus title), followed by a goto-link to the child's keyword on the line below.
- The parent receives one upward link to the `00.` index of indices, under the heading named by `autoslip-howm-master-link-heading` (default `Master Node`).
- The parent's Child Notes section is rebuilt at the end of the run in folgezettel order, so entries appear sorted regardless of import order. The rebuild also replaces any older bare-goto entries with the new heading-plus-goto format.

All four insertions are deduplicated, so re-running the command after adding new children to the source file inserts only what was missing.

A typical Child Notes block then looks like:

```org
** Child Notes

*** 1.1 Preparing for your study
>>> autoslip:1.1:hdfdep85

*** 1.1a Molecular structure defines function
>>> autoslip:1.1a:jxxfjbew
```

### Upgrading parent files written by older versions

Earlier releases wrote bare goto-lines under `Child Notes`, without the title heading. To upgrade a parent file in place, open it and run:

```
M-x autoslip-howm-rebuild-child-notes
```

That replaces the section with a sorted listing, with each entry as a level-3 heading carrying the child's title, followed by a goto-link.

### Following a link from an index file

When `autoslip-howm-mode` is enabled and you are inside an `.org` index file, put the cursor on any line containing an autoslip wiki keyword (either a `>>>` goto-link or a `<<<` self-anchor) and press `C-c C-o`. The package hooks into Org's `org-open-at-point-functions`, so Org's standard "open at point" command recognizes autoslip keywords and visits the corresponding note. Resolution uses the keyword's UID first and falls back to the address, which means the link keeps working after a reparent.

If you are in a plain-text howm file or just prefer a dedicated keybinding, use:

```
M-x autoslip-howm-follow-link-at-point
```

```elisp
;; Suggested key binding for any major mode.
(define-key global-map (kbd "C-c m o") #'autoslip-howm-follow-link-at-point)
```

If `autoslip-howm-mode` is off, Org's `C-c C-o` falls back to its default behavior and ignores autoslip keywords.

```elisp
;; Suggested key binding.
(define-key howm-mode-map (kbd "C-c m C") #'autoslip-howm-import-children-from-obsidian)
```

The command is the right tool for bulk ingestion. To add an upward link to `00.` from any note without running an import, use `M-x autoslip-howm-add-master-link` directly.

## Importing a single atomic note from Obsidian

For migrating one Obsidian note at a time, with body content intact, use:

```
M-x autoslip-howm-import-note-from-obsidian RET /path/to/1.1a Title.md RET
```

The file is expected to look like this:

```markdown
---
title: Molecular structure defines function
tags:
  - index-note
  - crystallography
date-created: 2026-03-25
source: "[[1.1 Preparing for your study]]"
---

# Molecular structure defines function

The molecular structure of matter defines its properties and function,
motivating the use of X-ray crystallography for atomic-resolution
structure determination.

## Parent Note
- [1.1 Preparing for your study](1.1%20Preparing%20for%20your%20study.md)

## Child Notes


## Related Notes
- (to be filled in later)
```

What the importer extracts:

- **Address.** From the file name's leading folgezettel (`1.1a` here).
- **Title.** From the YAML `title` field if present, otherwise the H1, otherwise the rest of the file name.
- **Body.** Everything between the H1 and the first auto-managed section (`## Parent Note`, `## Child Notes`, `## Related Notes`). Auto-managed sections are dropped because Howm regenerates them from cache.
- **Parent address.** From the YAML `source` field (parsed for a leading folgezettel inside `[[...]]`), falling back to the address-derived parent.

After parsing, the file is routed through the same four-tier reconciliation. The imported body is then written into the body region between the self-anchor and the first Howm-managed section. The default body strategy is `replace`; change it with:

```elisp
(setq autoslip-howm-import-note-body-strategy 'append)   ;; or 'prompt
```

If the parent note exists in the Howm vault, a bidirectional link is set up: the imported note gets a `Parent Note` reference back to the parent, and the parent gets a `Child Notes` reference forward to the imported note. Both inserts are deduplicated.

Tags, `date-created`, and the Obsidian-managed `Parent Note` / `Child Notes` / `Related Notes` sections in the source file are not carried over. If you want them in Howm, add them by hand after the import.

```elisp
;; Suggested key binding.
(define-key howm-mode-map (kbd "C-c m N") #'autoslip-howm-import-note-from-obsidian)
```

## Bulk import from Finder selection or a directory

Two commands wrap the single-note importer for bulk migration.

### From a Finder selection (macOS)

Select the `.md` files you want to migrate in Finder, then in Emacs:

```
M-x autoslip-howm-import-notes-from-finder-selection
```

The command shells out to `osascript` to read Finder's current selection, filters the list to `.md` files, asks for confirmation, and then routes each file through the single-atomic-note path. The macOS dependency is real: the command refuses to run when `osascript` is not on `PATH`. The AppleScript snippet is exposed as `autoslip-howm-finder-selection-applescript` if you need to customize it (for example to walk into bundles).

Per-file failures are collected in `*Autoslip-Howm Bulk Import Errors*` and do not abort the rest of the run. The end-of-run message reports the totals:

```
Imported 24/26 files from Finder selection (1 skipped, 1 errors)
```

`skipped` counts files whose name carries no leading folgezettel; `errors` counts files that failed during parse or reconciliation.

In this bulk path the `prompt` value of `autoslip-howm-import-note-body-strategy` silently falls back to `replace` to avoid asking once per file. Set the strategy to `'replace` explicitly if you want this behavior always, or to `'append` to add the imported body below any existing content.

### From a directory

Cross-platform alternative when you have your Obsidian notes laid out in a folder:

```
M-x autoslip-howm-import-notes-from-directory RET /path/to/obsidian/vault RET
```

Non-recursive by default. Prefix-argument (`C-u M-x ...`) descends into subdirectories.

```elisp
;; Suggested key bindings.
(define-key howm-mode-map (kbd "C-c m F") #'autoslip-howm-import-notes-from-finder-selection)
(define-key howm-mode-map (kbd "C-c m D") #'autoslip-howm-import-notes-from-directory)
```

## Commands

| Command | Description |
|---------|-------------|
| `autoslip-howm-mode` | Toggle the global minor mode |
| `autoslip-howm-create-note` | Create a note at an arbitrary address (the way to mint a root) |
| `autoslip-howm-insert-next-child` | Create a new child note under the current note |
| `autoslip-howm-add-backlink-to-parent` | Add bidirectional links manually |
| `autoslip-howm-report-validation-errors` | Validate an address |
| `autoslip-howm-diagnose-address` | Debug address lookup |
| `autoslip-howm-check-duplicate-index` | Check whether an address is taken |
| `autoslip-howm-goto-parent` | Visit the parent of the current note |
| `autoslip-howm-list-children` | Pick a direct child and visit it |
| `autoslip-howm-show-tree` | Display the whole vault as a folgezettel-ordered tree |
| `autoslip-howm-open-index` | Open `00.`, creating it if absent, seeded with the root list |
| `autoslip-howm-insert-root-list` | Insert a sorted block of every root at point |
| `autoslip-howm-insert-hub-index` | Insert an index of direct children only (vertical) |
| `autoslip-howm-insert-topic-index` | Insert an index of every note matching a regex (horizontal) |
| `autoslip-howm-import-from-obsidian` | Import a 00. markdown index from Obsidian and create the matching root notes |
| `autoslip-howm-import-children-from-obsidian` | Import a markdown child list under a parent and wire up bidirectional links |
| `autoslip-howm-import-note-from-obsidian` | Import a single atomic Obsidian note (body and parent link) |
| `autoslip-howm-import-notes-from-finder-selection` | Bulk-import every .md file selected in macOS Finder |
| `autoslip-howm-import-notes-from-directory` | Bulk-import every .md file in a directory (prefix-arg: recursive) |
| `autoslip-howm-add-master-link` | Insert an upward link from the current note to the 00. index |
| `autoslip-howm-rebuild-child-notes` | Replace the Child Notes section in the current note with a sorted, titled listing |
| `autoslip-howm-follow-link-at-point` | Visit the note named by the autoslip keyword on the current line |
| `autoslip-howm-show-chain-of-thought` | Show the ancestor chain in a buffer |
| `autoslip-howm-insert-chain-of-thought` | Insert the ancestor chain at point |
| `autoslip-howm-show-crosslinked-chains` | Stub, scheduled for a later phase |
| `autoslip-howm-reparent` | Move the current note to a new address |
| `autoslip-howm-reparent-subtree` | Move the current note and all descendants |
| `autoslip-howm-rescan` | Refresh the in-memory cache |

## Suggested key bindings

```elisp
(with-eval-after-load 'howm
  (define-key howm-mode-map (kbd "C-c o c") #'autoslip-howm-insert-next-child)
  (define-key howm-mode-map (kbd "C-c o p") #'autoslip-howm-add-backlink-to-parent)
  (define-key howm-mode-map (kbd "C-c o u") #'autoslip-howm-goto-parent)
  (define-key howm-mode-map (kbd "C-c o d") #'autoslip-howm-list-children)
  (define-key howm-mode-map (kbd "C-c o t") #'autoslip-howm-show-tree)
  (define-key howm-mode-map (kbd "C-c o i") #'autoslip-howm-open-index)
  (define-key howm-mode-map (kbd "C-c o I") #'autoslip-howm-insert-root-list)
  (define-key howm-mode-map (kbd "C-c o h") #'autoslip-howm-show-chain-of-thought)
  (define-key howm-mode-map (kbd "C-c o H") #'autoslip-howm-insert-chain-of-thought)
  (define-key howm-mode-map (kbd "C-c o r") #'autoslip-howm-reparent)
  (define-key howm-mode-map (kbd "C-c o R") #'autoslip-howm-reparent-subtree))
```

## Testing

```bash
make test
make compile
make check
```

The test suite does not require howm itself; it builds a temporary directory of fixture notes and exercises the autoslip-howm code paths against it.

## Implementation status

This is the Phase 1 scaffold from the project plan. 
The pure helpers (parsing, validation, suggestion, comparison, ancestor walk), the cache, the link writers, the create command, the navigation commands, and a baseline reparent implementation are in place. 
The chain-of-thought buffer and the cross-linked chains buffer are scheduled for Phase 5.

## License

GNU General Public License v3.0 or later. See `LICENSE`.

## Funding

- NIH: R01 CA242845, R01 AI088011
- NIH: P30 CA225520 (PI: R. Mannel); P30 GM145423 (PI: A. West)
