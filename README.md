# Autoslip-Howm

![Version](https://img.shields.io/static/v1?label=autoslip-howm&message=0.1.0&color=brightcolor)
[![License: GPL v3](https://img.shields.io/badge/License-GPLv3-blue.svg)](https://www.gnu.org/licenses/gpl-3.0)
[![Emacs](https://img.shields.io/badge/Emacs-27.1+-blueviolet.svg)](https://www.gnu.org/software/emacs/)
[![howm](https://img.shields.io/badge/howm-1.4.x-green.svg)](https://kaorahi.github.io/howm/)

Automatic folgezettel (computer-compatible Luhmann-style) bidirectional link generation for [howm](https://kaorahi.github.io/howm/).

This package brings the same workflow as [autoslip-roam](https://github.com/MooersLab/autoslip-roam) to howm users. It uses the folgezettel index in a note's title to determine parent-child relationships, then writes goto-links and come-from anchors so that howm's keyword search retrieves both directions of every relationship.

The folgezettel index appears at the start of the title and at the start of the filename. The package is compatible with printing notes for storage in a paper-based zettelkasten.

## Why a port

Howm has no central database, no node IDs, and no `org-roam-capture-` hook. Notes are plain files in a directory tree, and links are wiki keywords. autoslip-howm replaces the org-roam-specific machinery in autoslip-roam with a directory scan, a stable wiki-keyword scheme, and a `howm-create-file-hook` integration.

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

The string after the namespace is the visible folgezettel address. The string after the second colon is a UID minted at note creation. Inbound links are written with the goto marker:

```
>>> autoslip:1.2a:k7n3p3qr
```

The UID does the load-bearing work. The address segment can be rewritten on reparent. Inbound goto-links remain valid because their UIDs match.

## Title model

The title is the first non-empty line of the file. Common howm and org markers (`#+TITLE:`, `= `, `, M `, `, `) are stripped before the folgezettel is extracted. Any non-empty first line is acceptable.

## File-naming convention

```
ADDRESS-SLUG.EXT
```

Examples: `1.2a-crystal-symmetry.org`, `1.2a-crystal-symmetry.txt`. The address comes first by user preference. The slug is generated from the title at creation time. The extension is governed by `autoslip-howm-default-extension` (default `.org`).

## Installation

Manual installation:

```bash
git clone https://github.com/MooersLab/autoslip-howm.git
```

```elisp
(add-to-list 'load-path "/path/to/autoslip-howm")
(require 'autoslip-howm)
(setq autoslip-howm-directory "~/howm/")
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
| `autoslip-howm-show-chain-of-thought` | Show the ancestor chain in a buffer |
| `autoslip-howm-insert-chain-of-thought` | Insert the ancestor chain at point |
| `autoslip-howm-show-crosslinked-chains` | Stub, scheduled for a later phase |
| `autoslip-howm-reparent` | Move the current note to a new address |
| `autoslip-howm-reparent-subtree` | Move the current note and all descendants |
| `autoslip-howm-rescan` | Refresh the in-memory cache |

## Suggested key bindings

```elisp
(with-eval-after-load 'howm
  (define-key howm-mode-map (kbd "C-c m c") #'autoslip-howm-insert-next-child)
  (define-key howm-mode-map (kbd "C-c m p") #'autoslip-howm-add-backlink-to-parent)
  (define-key howm-mode-map (kbd "C-c m u") #'autoslip-howm-goto-parent)
  (define-key howm-mode-map (kbd "C-c m d") #'autoslip-howm-list-children)
  (define-key howm-mode-map (kbd "C-c m t") #'autoslip-howm-show-tree)
  (define-key howm-mode-map (kbd "C-c m h") #'autoslip-howm-show-chain-of-thought)
  (define-key howm-mode-map (kbd "C-c m H") #'autoslip-howm-insert-chain-of-thought)
  (define-key howm-mode-map (kbd "C-c m r") #'autoslip-howm-reparent)
  (define-key howm-mode-map (kbd "C-c m R") #'autoslip-howm-reparent-subtree))
```

## Testing

```bash
make test
make compile
make check
```

The test suite does not require howm itself; it builds a temporary directory of fixture notes and exercises the autoslip-howm code paths against it.

## Implementation status

This is the Phase 1 scaffold from the project plan. The pure helpers (parsing, validation, suggestion, comparison, ancestor walk), the cache, the link writers, the create command, the navigation commands, and a baseline reparent implementation are in place. The chain-of-thought buffer and the cross-linked chains buffer are scheduled for Phase 5.

## License

GNU General Public License v3.0 or later. See `LICENSE`.

## Funding

- NIH: R01 CA242845, R01 AI088011
- NIH: P30 CA225520 (PI: R. Mannel); P30 GM145423 (PI: A. West)
