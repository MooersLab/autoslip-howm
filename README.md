# Autoslip-Howm

![Version](https://img.shields.io/static/v1?label=autoslip-howm&message=0.1.0&color=brightcolor)
[![License: GPL v3](https://img.shields.io/badge/License-GPLv3-blue.svg)](https://www.gnu.org/licenses/gpl-3.0)
[![Emacs](https://img.shields.io/badge/Emacs-27.1+-blueviolet.svg)](https://www.gnu.org/software/emacs/)
[![howm](https://img.shields.io/badge/howm-1.4.x-green.svg)](https://kaorahi.github.io/howm/)

Automatic folgezettel (computer-compatible Luhmann-style) bidirectional link generation for [howm](https://kaorahi.github.io/howm/).

This package brings the same workflow as [autoslip-roam](https://github.com/MooersLab/autoslip-roam) to howm users. 
It uses the folgezettel index in a note's title to determine parent-child relationships, 
then writes goto-links and come-from anchors so that howm's keyword search retrieves both directions of every relationship.

The folgezettel index appears at the start of the title and at the start of the filename. 
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
The slug is generated from the title at creation time. 
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

Create a root note. The first non-empty line is the title:

```
1. Crystallography
```

Save the file. The package writes a self-anchor:

```
1. Crystallography
<<< autoslip:1.:k7n3p3qr
```

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

## Storage modes

- `headings` (default) writes visible `Parent Note` and `Child Notes` sections in the body. In `.org` files the heading uses stars; in plain-text files the heading uses the configurable `autoslip-howm-text-heading-format`.
- `headers` writes a top-of-file header block of the form `@FZ_PARENT: autoslip:1.:k7n3p3qr` and `@FZ_CHILDREN: autoslip:1.2:r2x9b7vt, autoslip:1.3:m4q1d9s2`. Body stays clean.

Switch modes with `(setq autoslip-howm-link-storage 'headers)`.

## Index of Indices

The roots of a folgezettel zettelkasten are the small set of major topics that organize everything else. In autoslip-howm those roots have addresses like `1.`, `2.`, `3.`. 
Each root anchors a chain of thought that grows downward through child notes such as `1.2`, `1.2a`, `1.2a3`. 
A single visit to the vault rarely shows every root at once. 
The `00. Index of Indices` note solves that problem. 
It is a flat catalog of every root, and it lives at a numerically lower address than `1.`, so it sorts to the top of the tree view and to the top of any directory listing.

The package treats every `N.` address as a root with no parent. The double-zero in `00.` is a sibling root, not a parent of `1.`, `2.`, and the rest. 
This is the right semantics, because the index of indices is a pointer page, not a parent. 
The single-digit form `0.` would also sort early, but `00` reads as an obvious meta-marker.

### Workflow

Sit with paper or a whiteboard for an hour and list the major areas of knowledge you want this zettelkasten to cover. 
Pick between five and twenty. 
Fewer than five is too coarse, and more than twenty is too many to keep in working memory while note-taking. 
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

## Commands

| Command | Description |
|---------|-------------|
| `autoslip-howm-mode` | Toggle the global minor mode |
| `autoslip-howm-insert-next-child` | Create a new child note |
| `autoslip-howm-add-backlink-to-parent` | Add bidirectional links manually |
| `autoslip-howm-report-validation-errors` | Validate an address |
| `autoslip-howm-diagnose-address` | Debug address lookup |
| `autoslip-howm-check-duplicate-index` | Check whether an address is taken |
| `autoslip-howm-goto-parent` | Visit the parent of the current note |
| `autoslip-howm-list-children` | Pick a direct child and visit it |
| `autoslip-howm-show-tree` | Display the whole vault as a folgezettel-ordered tree |
| `autoslip-howm-open-index` | Open `00.`, creating it if absent, seeded with the root list |
| `autoslip-howm-insert-root-list` | Insert a sorted block of every root at point |
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
