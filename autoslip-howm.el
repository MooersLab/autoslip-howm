;;; autoslip-howm.el --- Automatic folgezettel backlink generation for howm -*- lexical-binding: t; -*-

;; Copyright (C) 2026  Blaine Mooers

;; Author: Blaine Mooers <blaine-mooers@ou.edu>
;; Version: 0.1.0
;; Package-Requires: ((emacs "27.1"))
;; Keywords: outlines, howm, zettelkasten, folgezettel
;; URL: https://github.com/MooersLab/autoslip-howm

;; This program is free software; you can redistribute it and/or modify
;; it under the terms of the GNU General Public License as published by
;; the Free Software Foundation, either version 3 of the License, or
;; (at your option) any later version.

;; This program is distributed in the hope that it will be useful,
;; but WITHOUT ANY WARRANTY; without even the implied warranty of
;; MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
;; GNU General Public License for more details.

;;; Commentary:

;; This package brings the folgezettel-driven, automatic, bidirectional
;; linking model of `autoslip-roam' to howm (https://kaorahi.github.io/howm/).
;;
;; A "folgezettel" is a Luhmann-style address that locates a note in a
;; tree of related notes, for example "1.", "1.2", "1.2a", "1.2a3".
;; When a note's title carries a folgezettel, this package can:
;;
;; 1. Identify the parent note's address by stripping the trailing
;;    segment of the address.
;; 2. Find the parent note by scanning `autoslip-howm-directory'.
;; 3. Write a goto-link in the child that points at the parent's
;;    stable wiki keyword.
;; 4. Write a goto-link in the parent that points at the child.
;;
;; Identity model.
;;
;;   Each note holds a stable wiki keyword of the form
;;       <<< autoslip:ADDRESS:UID
;;   where ADDRESS is the visible folgezettel and UID is a unique
;;   identifier minted at note creation.  Inbound links are written
;;   as
;;       >>> autoslip:ADDRESS:UID
;;   The UID is the load-bearing piece.  ADDRESS may be rewritten on
;;   reparent without breaking inbound links.
;;
;; Title model.
;;
;;   The title is the first non-empty line of the file.  The package
;;   strips howm title markers (",", ", M", "= ") if present and then
;;   extracts the leading folgezettel from what remains.
;;
;; File naming.
;;
;;   ADDRESS-SLUG.EXT, for example "1.2a-crystal-symmetry.org".
;;
;; This is a Phase 1 scaffold.  Pure helpers (parsing, validation,
;; suggestion, comparison, ancestor walk) are fully ported from
;; autoslip-roam.  The backend layer (note enumeration, link writing,
;; hook wiring, navigation commands, reparent) is implemented to a
;; working baseline; later phases will add the chain-of-thought buffer,
;; the cross-linked chains buffer, and tighter howm integration.

;;; Code:

(require 'cl-lib)
(require 'seq)
(require 'subr-x)

(defgroup autoslip-howm nil
  "Automatic folgezettel backlink generation for howm."
  :group 'outlines
  :prefix "autoslip-howm-")


;;; ============================================================================
;;; Customization
;;; ============================================================================

(defcustom autoslip-howm-directory
  (or (and (boundp 'howm-directory) howm-directory)
      "~/howm/")
  "Directory scanned for howm notes that participate in folgezettel.
Defaults to `howm-directory' when howm is loaded, otherwise to
\"~/howm/\"."
  :type 'directory
  :group 'autoslip-howm)

(defcustom autoslip-howm-default-extension ".org"
  "File extension used for new notes created by autoslip-howm.
Either \".org\" for org-flavored howm or \".txt\" for plain-text howm."
  :type '(choice (const :tag "Org-mode (.org)" ".org")
                 (const :tag "Plain text (.txt)" ".txt")
                 (string :tag "Other"))
  :group 'autoslip-howm)

(defcustom autoslip-howm-index-file-name "00.-index-of-indices.org"
  "Name of the catalog file that lists every root note.
The file lives at the top of `autoslip-howm-directory'.  It sorts
above any real-root file (\"1.\", \"2.\", and so on) in any
lexicographic listing.  This file is a navigation hub, not a
parent of the real roots."
  :type 'string
  :group 'autoslip-howm)

(defcustom autoslip-howm-obsidian-project-heading-regexp
  "^##[ \t]+Project[ \t]+Support[ \t]*$"
  "Regexp matching the markdown heading that introduces project roots.
Used by `autoslip-howm-import-from-obsidian' to split a markdown
index of indices into a knowledge section and a project-support
section.  Lines after this heading are treated as project entries."
  :type 'regexp
  :group 'autoslip-howm)

(defcustom autoslip-howm-obsidian-project-offset 400
  "Integer offset added to project-section root numbers on import.
The default of 400 maps Obsidian's project numbers 100, 101, 102 to
Howm's 500, 501, 502.  Set to 0 to keep the original numbering."
  :type 'integer
  :group 'autoslip-howm)

(defcustom autoslip-howm-hub-index-heading-format "Children of %s"
  "Heading text used by `autoslip-howm-insert-hub-index'.
Receives the current note's folgezettel as its single argument."
  :type 'string
  :group 'autoslip-howm)

(defcustom autoslip-howm-topic-index-heading-format "Topic Index: %s"
  "Heading text used by `autoslip-howm-insert-topic-index'.
Receives the search term as its single argument."
  :type 'string
  :group 'autoslip-howm)

(defcustom autoslip-howm-search-backend 'auto
  "Backend used by `autoslip-howm-insert-topic-index' to find matches.

Possible values:

`auto'   Use ripgrep when on PATH, then GNU grep, then the
         in-Emacs scan.  This is the default and the right choice
         for almost everyone.

`rg'     Always shell out to ripgrep.  Fastest on large vaults
         (tens of thousands of notes).  Requires `rg' on PATH.

`grep'   Always shell out to grep.  Portable and present on most
         systems.  Slower than rg but much faster than the
         in-Emacs scan.  Requires `grep' on PATH.

`emacs'  Always use the in-Emacs scan.  Useful when you need
         Emacs-flavor regex (\\b, \\<, \\>, \\\\=) or when no
         external tools are available.

The regex flavor depends on the chosen backend.  rg uses Rust
regex syntax, grep uses ERE (with `-E'), and the in-Emacs scan
uses Emacs regex.  For literal words, character classes, the
anchors `^' and `$', alternation, and the common quantifiers, all
three flavors behave identically."
  :type '(choice (const :tag "Auto-detect (rg, then grep, then Emacs)" auto)
                 (const :tag "Ripgrep (rg)" rg)
                 (const :tag "GNU grep" grep)
                 (const :tag "In-Emacs scan" emacs))
  :group 'autoslip-howm)

(defcustom autoslip-howm-rg-program "rg"
  "Name or absolute path of the ripgrep executable."
  :type 'string
  :group 'autoslip-howm)

(defcustom autoslip-howm-grep-program "grep"
  "Name or absolute path of the grep executable."
  :type 'string
  :group 'autoslip-howm)

(defcustom autoslip-howm-file-name-regexp
  "\\.\\(org\\|txt\\|howm\\|md\\)\\'"
  "Regexp matching file names that autoslip-howm should consider notes."
  :type 'regexp
  :group 'autoslip-howm)

(defcustom autoslip-howm-anchor-marker "<<<"
  "Marker that defines a come-from anchor in a howm note.
In stock howm this declares \"this note is known by the following
keyword\".  Place at the start of a line, followed by a space and
the keyword."
  :type 'string
  :group 'autoslip-howm)

(defcustom autoslip-howm-goto-marker ">>>"
  "Marker that introduces a goto-link in a howm note.
In stock howm this means \"jump to the note that defines the
following keyword\"."
  :type 'string
  :group 'autoslip-howm)

(defcustom autoslip-howm-keyword-namespace "autoslip"
  "Namespace prefix used in autoslip-howm wiki keywords.
The full keyword has the form NAMESPACE:ADDRESS:UID, for example
\"autoslip:1.2a:k7n3p\"."
  :type 'string
  :group 'autoslip-howm)

(defcustom autoslip-howm-link-storage 'headings
  "How parent and child references are stored in notes.

Possible values:

`headings'    (default) Write visible headings (\"Parent Note\",
              \"Child Notes\") into the body of each note with
              links beneath them.  Heading style adapts to file
              flavor (org-mode versus plain-text howm).

`headers'    Store the parent keyword in a top-of-file header line
              under `autoslip-howm-parent-property' and the child
              keywords under `autoslip-howm-children-property'.
              This leaves the body of each file free of automatic
              link text and shrinks the surface area for merge
              conflicts in a synced or version-controlled vault."
  :type '(choice (const :tag "Visible headings (default)" headings)
                 (const :tag "Top-of-file header keywords" headers))
  :group 'autoslip-howm)

(defcustom autoslip-howm-parent-property "@FZ_PARENT"
  "Header keyword used to store the parent reference in `headers' mode."
  :type 'string
  :group 'autoslip-howm)

(defcustom autoslip-howm-children-property "@FZ_CHILDREN"
  "Header keyword used to store the child references in `headers' mode.
The value is a comma-separated list of full autoslip wiki keywords."
  :type 'string
  :group 'autoslip-howm)

(defcustom autoslip-howm-self-anchor t
  "Whether to write a self-anchor line at the top of every new note.
The self-anchor has the form
  ANCHOR-MARKER autoslip:ADDRESS:UID
and is what makes inbound goto-links resolvable."
  :type 'boolean
  :group 'autoslip-howm)

(defcustom autoslip-howm-backlink-heading "Parent Note"
  "Heading text used above the parent reference in `headings' mode.
Set to nil to insert the parent reference without a heading."
  :type '(choice (const :tag "No heading" nil)
                 (string :tag "Heading text"))
  :group 'autoslip-howm)

(defcustom autoslip-howm-forward-link-heading "Child Notes"
  "Heading text used above the child references in `headings' mode."
  :type '(choice (const :tag "No heading" nil)
                 (string :tag "Heading text"))
  :group 'autoslip-howm)

(defcustom autoslip-howm-crosslink-heading "Cross References"
  "Heading text used above auto-inserted reciprocal cross-links."
  :type '(choice (const :tag "No heading" nil)
                 (string :tag "Heading text"))
  :group 'autoslip-howm)

(defcustom autoslip-howm-master-link-heading "Master Node"
  "Heading text used above the upward link from a note to the 00. index.
The 00. index of indices acts as a navigation hub for the whole
vault, so each root note can carry one upward link to it.  Set this
to nil to insert the link without a heading."
  :type '(choice (const :tag "No heading" nil)
                 (string :tag "Heading text"))
  :group 'autoslip-howm)

(defcustom autoslip-howm-import-note-body-strategy 'replace
  "How `autoslip-howm-import-note-from-obsidian' writes the imported body.

Possible values:

`replace'  Overwrite the body region (between the self-anchor and
           the first Howm-managed section) with the imported text.
           The default.  Use this when the Obsidian file is
           authoritative.

`append'   Add the imported text below any existing body in the
           Howm file.

`prompt'   Ask before overwriting when the Howm file already has
           a non-empty body.  Falls back to `replace' on empty
           files."
  :type '(choice (const :tag "Replace" replace)
                 (const :tag "Append" append)
                 (const :tag "Prompt" prompt))
  :group 'autoslip-howm)

(defcustom autoslip-howm-rename-files-on-reparent t
  "Whether to rename files on disk when reparenting a note.
When non-nil, `autoslip-howm-reparent' substitutes the old
folgezettel with the new one in each affected file name."
  :type 'boolean
  :group 'autoslip-howm)

(defcustom autoslip-howm-regex
  "\\b\\([0-9]+\\(?:[.][0-9]+\\)*\\(?:[a-z]+\\(?:[0-9]+\\)?\\)*\\)\\(?:[^a-z0-9]\\|$\\)"
  "Regular expression that matches a folgezettel address.
Matches forms such as 1, 1.2, 1.13, 1.2a, 1.2aa, 1.2a15, 1.2a3c5d7a.
The trailing non-alphanumeric or end-of-string boundary keeps the
match from running into surrounding title text."
  :type 'regexp
  :group 'autoslip-howm)

(defcustom autoslip-howm-rescan-on-query t
  "Whether to refresh the in-memory note cache before each query.
Disable for very large vaults where the rescan becomes noticeable;
in that case call `autoslip-howm-rescan' explicitly."
  :type 'boolean
  :group 'autoslip-howm)

(defcustom autoslip-howm-text-heading-format ", M %s"
  "Format string used for headings in plain-text howm notes.
Receives the heading text as its single argument."
  :type 'string
  :group 'autoslip-howm)


;;; ============================================================================
;;; Pure helpers (ported verbatim from autoslip-roam, prefix renamed)
;;; ============================================================================

(defun autoslip-howm--root-address-p (address)
  "Return non-nil when ADDRESS is a root.
A root is digits with an optional trailing period."
  (and (stringp address)
       (string-match-p "\\`[0-9]+\\.?\\'" address)))

(defun autoslip-howm--canonicalize-root (address)
  "Return ADDRESS with a trailing period if it is a bare-integer root.
Non-root addresses are returned unchanged.  The trailing period is the
canonical marker for a root note."
  (cond
   ((not (stringp address)) address)
   ((string-match-p "\\`[0-9]+\\'" address) (concat address "."))
   (t address)))

(defun autoslip-howm--parse-address (folgezettel)
  "Parse FOLGEZETTEL and return the parent address, or nil at the root.

Examples:
  1.2a3c5   -> 1.2a3c
  1.13aa    -> 1.13
  1.13a     -> 1.13
  1.2a      -> 1.2
  1.13      -> 1.
  1.        -> nil
  1         -> nil"
  (when (and folgezettel (string-match autoslip-howm-regex folgezettel))
    (let ((addr folgezettel))
      (cond
       ((string-match "\\(.*[a-z]+\\)[0-9]+$" addr)
        (match-string 1 addr))
       ((string-match "\\(.*?\\)[a-z]+$" addr)
        (match-string 1 addr))
       ((string-match "\\(.*\\)[.][0-9]+$" addr)
        (concat (match-string 1 addr) "."))
       ((autoslip-howm--root-address-p addr)
        nil)
       (t nil)))))

(defun autoslip-howm--extract-from-title (title)
  "Extract a folgezettel address from TITLE, or nil if absent.
Bare-integer roots (\"1\") are canonicalized to \"1.\"."
  (when (and title (string-match autoslip-howm-regex title))
    (autoslip-howm--canonicalize-root (match-string 1 title))))

(defun autoslip-howm--next-letter-sequence (current)
  "Return the next letter sequence after CURRENT.
Examples: a -> b, z -> aa, az -> ba, zz -> aaa."
  (let* ((chars (string-to-list current))
         (result (reverse chars))
         (carry t))
    (setq result
          (mapcar (lambda (c)
                    (if carry
                        (if (= c ?z)
                            ?a
                          (setq carry nil)
                          (1+ c))
                      c))
                  result))
    (when carry
      (setq result (cons ?a result)))
    (concat (reverse result))))

(defun autoslip-howm--validate-no-multiple-periods (address)
  "Return an error string when ADDRESS would contain more than one period."
  (when (and address (stringp address))
    (let ((period-count (length (seq-filter (lambda (c) (= c ?.)) address))))
      (when (> period-count 1)
        (format
         "Invalid address '%s': Only one period is allowed.  Found %d."
         address period-count)))))

(defun autoslip-howm--validate-no-invalid-characters (address)
  "Return an error string when ADDRESS would contain invalid characters."
  (when (and address (stringp address))
    (let ((case-fold-search nil))
      (let ((cleaned (replace-regexp-in-string "[0-9a-z.]" "" address)))
        (when (> (length cleaned) 0)
          (format
           "Invalid address '%s': Contains invalid character(s): %s"
           address cleaned))))))

(defun autoslip-howm--validate-alternation-pattern (address)
  "Return an error string if ADDRESS violates the alternation rule.
Number segments and letter segments must alternate after the root."
  (when (and address (stringp address))
    (when (string-match "^[0-9]+\\(?:\\.[0-9]+\\)?\\(.*\\)$" address)
      (let ((suffix (match-string 1 address)))
        (when (> (length suffix) 0)
          (let ((segments '())
                (pos 0)
                (len (length suffix)))
            (while (< pos len)
              (cond
               ((string-match "\\`[a-z]+" (substring suffix pos))
                (let ((m (match-string 0 (substring suffix pos))))
                  (push (cons 'letters m) segments)
                  (setq pos (+ pos (length m)))))
               ((string-match "\\`[0-9]+" (substring suffix pos))
                (let ((m (match-string 0 (substring suffix pos))))
                  (push (cons 'numbers m) segments)
                  (setq pos (+ pos (length m)))))
               (t (setq pos len))))
            (setq segments (reverse segments))
            (let ((prev nil) (err nil))
              (dolist (seg segments)
                (when (and prev (eq prev (car seg)))
                  (setq err
                        (format
                         "Invalid address '%s': consecutive %s segments."
                         address (symbol-name (car seg)))))
                (setq prev (car seg)))
              err)))))))

(defun autoslip-howm--validate-child-for-parent (parent-address child-suffix)
  "Return an error string if CHILD-SUFFIX is not appropriate for PARENT-ADDRESS.

A parent ending in a number must be followed by a letter or by a
.number suffix.  A parent ending in a letter must be followed by a
number."
  (when (and parent-address child-suffix
             (stringp parent-address) (stringp child-suffix)
             (> (length parent-address) 0) (> (length child-suffix) 0))
    (let ((p (aref parent-address (1- (length parent-address))))
          (c (aref child-suffix 0)))
      (cond
       ((and (>= p ?0) (<= p ?9))
        (cond
         ((and (>= c ?a) (<= c ?z)) nil)
         ((= c ?.) nil)
         ((and (>= c ?0) (<= c ?9))
          (format "Invalid child suffix '%s' for parent '%s': use a letter or '.NUMBER'."
                  child-suffix parent-address))
         (t nil)))
       ((and (>= p ?a) (<= p ?z))
        (cond
         ((and (>= c ?0) (<= c ?9)) nil)
         ((and (>= c ?a) (<= c ?z))
          (format "Invalid child suffix '%s' for parent '%s': must start with a number."
                  child-suffix parent-address))
         (t nil)))
       (t nil)))))

(defun autoslip-howm-validate-address (address)
  "Return non-nil if ADDRESS is a valid folgezettel address."
  (and address
       (stringp address)
       (not (autoslip-howm--validate-no-invalid-characters address))
       (not (autoslip-howm--validate-no-multiple-periods address))
       (not (autoslip-howm--validate-alternation-pattern address))
       (string-match-p "^[0-9]+\\(?:\\.[0-9]*\\)?\\(?:[a-z]+[0-9]*\\)*$" address)))

(defun autoslip-howm-validate-address-full (address)
  "Validate ADDRESS and return a list of error strings, or nil if valid."
  (let ((errors '()))
    (unless (and address (stringp address))
      (push "Address must be a non-empty string." errors))
    (when (and address (stringp address))
      (when-let ((e (autoslip-howm--validate-no-invalid-characters address)))
        (push e errors))
      (when-let ((e (autoslip-howm--validate-no-multiple-periods address)))
        (push e errors))
      (when-let ((e (autoslip-howm--validate-alternation-pattern address)))
        (push e errors))
      (unless (string-match-p "^[0-9]" address)
        (push (format "Invalid address '%s': must start with a number." address)
              errors)))
    (reverse errors)))

(defun autoslip-howm-validate-new-child (parent-address child-address)
  "Validate that CHILD-ADDRESS is a child of PARENT-ADDRESS.
Return a list of error strings, or nil if valid."
  (let ((errors '()))
    (let ((pe (autoslip-howm-validate-address-full parent-address))
          (ce (autoslip-howm-validate-address-full child-address)))
      (when pe (push (format "Parent: %s" (string-join pe "; ")) errors))
      (when ce (push (format "Child: %s" (string-join ce "; ")) errors)))
    (when (and (null errors)
               parent-address child-address)
      (unless (string-prefix-p parent-address child-address)
        (push (format "Child '%s' must start with parent '%s'."
                      child-address parent-address)
              errors))
      (when (string-prefix-p parent-address child-address)
        (let ((suffix (substring child-address (length parent-address))))
          (when (= (length suffix) 0)
            (push "Child cannot equal parent." errors))
          (when (> (length suffix) 0)
            (when-let ((e (autoslip-howm--validate-child-for-parent
                           parent-address suffix)))
              (push e errors))))))
    (reverse errors)))

(defun autoslip-howm--address-depth (address)
  "Return the hierarchical depth of ADDRESS.  Roots have depth 0."
  (let ((depth 0)
        (cur address))
    (while (setq cur (autoslip-howm--parse-address cur))
      (setq depth (1+ depth)))
    depth))

(defun autoslip-howm--address-tokens (address)
  "Split ADDRESS into a list of comparable tokens.
Each token is either a number or a string of letters."
  (let ((tokens '())
        (pos 0)
        (len (length address)))
    (while (< pos len)
      (let ((c (aref address pos)))
        (cond
         ((= c ?.) (setq pos (1+ pos)))
         ((and (>= c ?0) (<= c ?9))
          (let ((start pos))
            (while (and (< pos len)
                        (let ((d (aref address pos)))
                          (and (>= d ?0) (<= d ?9))))
              (setq pos (1+ pos)))
            (push (string-to-number (substring address start pos)) tokens)))
         ((and (>= c ?a) (<= c ?z))
          (let ((start pos))
            (while (and (< pos len)
                        (let ((d (aref address pos)))
                          (and (>= d ?a) (<= d ?z))))
              (setq pos (1+ pos)))
            (push (substring address start pos) tokens)))
         (t (setq pos (1+ pos))))))
    (nreverse tokens)))

(defun autoslip-howm--compare-addresses (a b)
  "Return non-nil when address A should sort before B in hierarchical order."
  (let ((at (autoslip-howm--address-tokens a))
        (bt (autoslip-howm--address-tokens b))
        (result nil)
        (decided nil))
    (while (and (not decided) at bt)
      (let ((ax (car at))
            (bx (car bt)))
        (cond
         ((and (numberp ax) (numberp bx))
          (cond ((< ax bx) (setq decided t result t))
                ((> ax bx) (setq decided t result nil))
                (t (setq at (cdr at) bt (cdr bt)))))
         ((and (stringp ax) (stringp bx))
          (cond ((string< ax bx) (setq decided t result t))
                ((string< bx ax) (setq decided t result nil))
                (t (setq at (cdr at) bt (cdr bt)))))
         ((numberp ax) (setq decided t result t))
         (t (setq decided t result nil)))))
    (if decided
        result
      (< (length at) (length bt)))))

(defun autoslip-howm--ancestor-addresses (address)
  "Return ADDRESS and every ancestor, root-to-leaf order."
  (when (and address (stringp address) (not (string-empty-p address)))
    (let ((chain (list address))
          (cur address)
          (parent nil))
      (while (setq parent (autoslip-howm--parse-address cur))
        (push parent chain)
        (setq cur parent))
      chain)))


;;; ============================================================================
;;; Wiki keyword construction
;;; ============================================================================

(defun autoslip-howm--mint-uid ()
  "Return a short, opaque, unique identifier."
  (let* ((alphabet "abcdefghijkmnpqrstuvwxyz23456789")
         (n (length alphabet))
         (out (make-string 8 ?_)))
    (dotimes (i 8)
      (aset out i (aref alphabet (random n))))
    out))

(defun autoslip-howm--make-keyword (address uid)
  "Build the autoslip wiki keyword from ADDRESS and UID."
  (format "%s:%s:%s"
          autoslip-howm-keyword-namespace
          address uid))

(defun autoslip-howm--parse-keyword (keyword)
  "Parse KEYWORD into (NAMESPACE ADDRESS UID), or nil if it does not match."
  (when (and keyword (stringp keyword))
    (let ((ns (regexp-quote autoslip-howm-keyword-namespace)))
      (when (string-match
             (concat "\\`" ns ":\\([^:]+\\):\\([^:[:space:]]+\\)\\'")
             keyword)
        (list autoslip-howm-keyword-namespace
              (match-string 1 keyword)
              (match-string 2 keyword))))))

(defun autoslip-howm--keyword-address (keyword)
  "Return the ADDRESS field of KEYWORD, or nil."
  (nth 1 (autoslip-howm--parse-keyword keyword)))

(defun autoslip-howm--keyword-uid (keyword)
  "Return the UID field of KEYWORD, or nil."
  (nth 2 (autoslip-howm--parse-keyword keyword)))


;;; ============================================================================
;;; Note enumeration and lookup
;;; ============================================================================

(defvar autoslip-howm--cache nil
  "In-memory cache of parsed notes.
A list of plists, each with :file, :title, :address, :keyword.")

(defvar autoslip-howm--cache-time 0
  "Time of the last cache build, as a `float-time' value.")

(defun autoslip-howm--note-files ()
  "Return all candidate note files under `autoslip-howm-directory'."
  (let ((dir (expand-file-name autoslip-howm-directory)))
    (when (file-directory-p dir)
      (directory-files-recursively
       dir autoslip-howm-file-name-regexp))))

(defun autoslip-howm--read-first-nonempty-line (file)
  "Return the first non-empty line of FILE, or nil."
  (with-temp-buffer
    (condition-case _
        (insert-file-contents file nil 0 4096)
      (error nil))
    (goto-char (point-min))
    (let ((line nil))
      (while (and (not line) (not (eobp)))
        (let ((this (buffer-substring-no-properties
                     (line-beginning-position)
                     (line-end-position))))
          (if (string-match-p "\\`[ \t]*\\'" this)
              (forward-line 1)
            (setq line this))))
      line)))

(defun autoslip-howm--strip-title-marker (line)
  "Return LINE with leading howm or org title marker removed."
  (cond
   ((null line) nil)
   ((string-match "\\`\\(?:#\\+[Tt][Ii][Tt][Ll][Ee]:[ \t]*\\)\\(.*\\)$" line)
    (string-trim (match-string 1 line)))
   ((string-match "\\`= \\(.*\\)$" line)
    (string-trim (match-string 1 line)))
   ((string-match "\\`,[ \t]*M[ \t]+\\(.*\\)$" line)
    (string-trim (match-string 1 line)))
   ((string-match "\\`,[ \t]+\\(.*\\)$" line)
    (string-trim (match-string 1 line)))
   (t (string-trim line))))

(defun autoslip-howm--read-self-keyword (file)
  "Return the autoslip self-anchor keyword from FILE, or nil.
Reads the head of FILE and searches for a line of the form
ANCHOR-MARKER autoslip:ADDRESS:UID."
  (with-temp-buffer
    (condition-case _
        (insert-file-contents file nil 0 8192)
      (error nil))
    (goto-char (point-min))
    (let ((pat (concat "^"
                       (regexp-quote autoslip-howm-anchor-marker)
                       "[ \t]+\\("
                       (regexp-quote autoslip-howm-keyword-namespace)
                       ":[^[:space:]]+\\)")))
      (when (re-search-forward pat nil t)
        (match-string-no-properties 1)))))

(defun autoslip-howm--build-cache ()
  "Re-scan `autoslip-howm-directory' and return a fresh cache list."
  (let (out)
    (dolist (file (autoslip-howm--note-files))
      (let* ((line (autoslip-howm--read-first-nonempty-line file))
             (title (autoslip-howm--strip-title-marker line))
             (address (autoslip-howm--extract-from-title title))
             (keyword (autoslip-howm--read-self-keyword file)))
        (push (list :file file
                    :title title
                    :address address
                    :keyword keyword)
              out)))
    (nreverse out)))

(defun autoslip-howm-rescan ()
  "Refresh the in-memory note cache."
  (interactive)
  (setq autoslip-howm--cache (autoslip-howm--build-cache))
  (setq autoslip-howm--cache-time (float-time))
  (when (called-interactively-p 'any)
    (message "autoslip-howm: indexed %d note(s)"
             (length autoslip-howm--cache)))
  autoslip-howm--cache)

(defun autoslip-howm--maybe-rescan ()
  "Refresh the cache when `autoslip-howm-rescan-on-query' is non-nil."
  (when (or autoslip-howm-rescan-on-query
            (null autoslip-howm--cache))
    (autoslip-howm-rescan)))

(defun autoslip-howm--all-notes ()
  "Return the current cache, refreshing if needed."
  (autoslip-howm--maybe-rescan)
  autoslip-howm--cache)

(defun autoslip-howm--find-note-by-address (address)
  "Return the cached plist whose :address equals ADDRESS, or nil."
  (when address
    (seq-find (lambda (n) (and (plist-get n :address)
                               (string= (plist-get n :address) address)))
              (autoslip-howm--all-notes))))

(defun autoslip-howm--find-note-by-uid (uid)
  "Return the cached plist whose self keyword has UID, or nil."
  (when uid
    (seq-find (lambda (n)
                (let ((k (plist-get n :keyword)))
                  (and k (string= (autoslip-howm--keyword-uid k) uid))))
              (autoslip-howm--all-notes))))

(defun autoslip-howm--find-note-at-point ()
  "Return the cached plist for the note in the current buffer, or nil.
The note is identified by buffer file name."
  (when buffer-file-name
    (let ((file (expand-file-name buffer-file-name)))
      (seq-find (lambda (n)
                  (string= (expand-file-name (plist-get n :file)) file))
                (autoslip-howm--all-notes)))))


;;; ============================================================================
;;; Diagnostics
;;; ============================================================================

(defun autoslip-howm-diagnose-address (address)
  "Print a diagnostic listing of every cached note's address.
Highlights matches for ADDRESS."
  (interactive "sFolgezettel address to diagnose: ")
  (autoslip-howm--maybe-rescan)
  (let ((notes (autoslip-howm--all-notes))
        (hit nil))
    (with-output-to-temp-buffer "*Autoslip-Howm Diagnose*"
      (princ (format "Diagnosing address: %s\n" address))
      (princ (format "Indexed %d note(s).\n\n" (length notes)))
      (dolist (n notes)
        (let ((a (plist-get n :address)))
          (when a
            (when (string= a address) (setq hit n))
            (princ (format "  %-12s  %s\n"
                           (or a "(none)")
                           (or (plist-get n :title) "")))))))
    (if hit
        (message "Match: %s -> %s" address (plist-get hit :file))
      (message "No note found with address '%s'" address))))

(defun autoslip-howm-check-duplicate-index (address)
  "Return t if ADDRESS is available, nil if it is already used.
Warns the user if duplicate."
  (interactive "sFolgezettel address to check: ")
  (autoslip-howm--maybe-rescan)
  (let ((existing (autoslip-howm--find-note-by-address address)))
    (cond
     (existing
      (display-warning
       'autoslip-howm
       (format "Duplicate address '%s' is already used by:\n  %s"
               address
               (or (plist-get existing :title)
                   (plist-get existing :file)))
       :warning)
      nil)
     (t
      (when (called-interactively-p 'any)
        (message "Address '%s' is available." address))
      t))))

(defun autoslip-howm-report-validation-errors (address)
  "Validate ADDRESS and message each error.  Return non-nil if valid."
  (interactive "sFolgezettel address to validate: ")
  (let ((errors (autoslip-howm-validate-address-full address)))
    (if errors
        (progn
          (message "Validation FAILED for '%s':\n%s"
                   address (string-join errors "\n"))
          nil)
      (message "Validation PASSED for '%s'." address)
      t)))


;;; ============================================================================
;;; Suggesting child addresses
;;; ============================================================================

(defun autoslip-howm--children-notes-of (parent-address)
  "Return cached note plists whose direct parent is PARENT-ADDRESS."
  (when parent-address
    (let ((canonical (autoslip-howm--canonicalize-root parent-address)))
      (seq-filter
       (lambda (n)
         (let* ((fz (plist-get n :address))
                (p (and fz (autoslip-howm--parse-address fz))))
           (and p (string= p canonical))))
       (autoslip-howm--all-notes)))))

(defun autoslip-howm-suggest-next-child (parent-address)
  "Return a list of valid next-child addresses for PARENT-ADDRESS."
  (let ((errors (autoslip-howm-validate-address-full parent-address)))
    (if errors
        (progn
          (message "Cannot suggest children: %s"
                   (string-join errors "; "))
          nil)
      (let* ((canonical (autoslip-howm--canonicalize-root parent-address))
             (children (autoslip-howm--children-notes-of canonical))
             (parent-ends-with-letter
              (and (> (length canonical) 0)
                   (let ((c (aref canonical (1- (length canonical)))))
                     (and (>= c ?a) (<= c ?z)))))
             (parent-is-root (autoslip-howm--root-address-p canonical))
             (parent-has-dot (and (not parent-is-root)
                                  (string-match-p "\\." canonical)))
             (max-num-with-dot 0)
             (max-num-after-letter 0)
             (max-letter nil))
        (dolist (child children)
          (when-let ((fz (plist-get child :address)))
            (cond
             ((and parent-is-root
                   (string-match
                    (concat "^"
                            (regexp-quote
                             (if (string-suffix-p "." canonical)
                                 (substring canonical 0 -1)
                               canonical))
                            "[.]\\([0-9]+\\)")
                    fz))
              (setq max-num-with-dot
                    (max max-num-with-dot (string-to-number (match-string 1 fz)))))
             ((and parent-ends-with-letter
                   (string-match (concat "^" (regexp-quote canonical)
                                         "\\([0-9]+\\)")
                                 fz))
              (setq max-num-after-letter
                    (max max-num-after-letter (string-to-number (match-string 1 fz)))))
             ((and (not parent-ends-with-letter)
                   parent-has-dot
                   (string-match (concat "^" (regexp-quote canonical)
                                         "\\([a-z]+\\)")
                                 fz))
              (let ((letters (match-string 1 fz)))
                (when (or (not max-letter) (string< max-letter letters))
                  (setq max-letter letters)))))))
        (cond
         (parent-ends-with-letter
          (list (concat canonical
                        (number-to-string (1+ max-num-after-letter)))))
         (parent-is-root
          (list (concat canonical
                        (unless (string-suffix-p "." canonical) ".")
                        (number-to-string (1+ max-num-with-dot)))))
         (parent-has-dot
          (list (concat canonical
                        (if max-letter
                            (autoslip-howm--next-letter-sequence max-letter)
                          "a"))))
         (t nil))))))


;;; ============================================================================
;;; File creation and naming
;;; ============================================================================

(defun autoslip-howm--slugify (text)
  "Return a filename-safe slug for TEXT."
  (let ((s (downcase (or text ""))))
    (setq s (replace-regexp-in-string "[^a-z0-9]+" "-" s))
    (setq s (replace-regexp-in-string "\\`-+\\|-+\\'" "" s))
    (if (string-empty-p s) "note" s)))

(defun autoslip-howm--filename-for (address title)
  "Return the absolute filename for a new note with ADDRESS and TITLE."
  (let* ((slug (autoslip-howm--slugify title))
         (base (format "%s-%s%s"
                       address slug
                       autoslip-howm-default-extension)))
    (expand-file-name base autoslip-howm-directory)))

(defun autoslip-howm--org-flavor-p (file)
  "Return non-nil if FILE is org-flavored."
  (string-match-p "\\.org\\'" (or file "")))

(defun autoslip-howm--format-heading (text level &optional file)
  "Return TEXT formatted as a heading at LEVEL for FILE flavor.
Org files use stars; plain-text files use the configured marker."
  (cond
   ((and file (autoslip-howm--org-flavor-p file))
    (format "%s %s" (make-string level ?*) text))
   (t
    (format autoslip-howm-text-heading-format text))))


;;; ============================================================================
;;; Link writing
;;; ============================================================================

(defun autoslip-howm--goto-line (text)
  "Return a goto-link line for keyword TEXT."
  (format "%s %s\n" autoslip-howm-goto-marker text))

(defun autoslip-howm--anchor-line (keyword)
  "Return an anchor line for KEYWORD."
  (format "%s %s\n" autoslip-howm-anchor-marker keyword))

(defun autoslip-howm--ensure-self-anchor (address)
  "Ensure the current buffer has a self-anchor for ADDRESS.
Returns the keyword (existing or newly created)."
  (let* ((existing (save-excursion
                     (goto-char (point-min))
                     (when (re-search-forward
                            (concat "^"
                                    (regexp-quote autoslip-howm-anchor-marker)
                                    "[ \t]+\\("
                                    (regexp-quote autoslip-howm-keyword-namespace)
                                    ":[^[:space:]]+\\)")
                            nil t)
                       (match-string-no-properties 1)))))
    (or existing
        (let* ((uid (autoslip-howm--mint-uid))
               (kw (autoslip-howm--make-keyword address uid)))
          (save-excursion
            (goto-char (point-min))
            (forward-line 1)
            (unless (bolp) (insert "\n"))
            (insert (autoslip-howm--anchor-line kw)))
          kw))))

(defun autoslip-howm--insert-under-heading (heading line)
  "Find or create HEADING in the current buffer and insert LINE under it.
HEADING is the text of the heading; LINE is a complete line including
the trailing newline."
  (let* ((file buffer-file-name)
         (formatted (autoslip-howm--format-heading heading 2 file))
         (search-pat
          (concat "^" (regexp-quote
                       (autoslip-howm--format-heading heading 2 file))
                  "[ \t]*$")))
    (save-excursion
      (goto-char (point-min))
      (if (re-search-forward search-pat nil t)
          (progn
            (end-of-line)
            (insert "\n" line))
        (goto-char (point-max))
        (unless (bolp) (insert "\n"))
        (insert "\n" formatted "\n" line)))))

(defun autoslip-howm--insert-backlink-headings (parent-keyword)
  "Write a goto-link to PARENT-KEYWORD in the current buffer using `headings' mode."
  (if autoslip-howm-backlink-heading
      (autoslip-howm--insert-under-heading
       autoslip-howm-backlink-heading
       (autoslip-howm--goto-line parent-keyword))
    (save-excursion
      (goto-char (point-min))
      (forward-line 2)
      (insert (autoslip-howm--goto-line parent-keyword)))))

(defun autoslip-howm--get-header-property (key)
  "Return the value of the top-of-file header KEY in this buffer, or nil."
  (save-excursion
    (goto-char (point-min))
    (let ((limit (save-excursion
                   (forward-line 30)
                   (point))))
      (when (re-search-forward
             (concat "^" (regexp-quote key) ":[ \t]*\\(.*\\)$")
             limit t)
        (let ((v (match-string-no-properties 1)))
          (and v (not (string-empty-p v))
               (string-trim-right v)))))))

(defun autoslip-howm--set-header-property (key value)
  "Set or insert the top-of-file header KEY to VALUE in this buffer."
  (save-excursion
    (goto-char (point-min))
    (let ((limit (save-excursion
                   (forward-line 30)
                   (point))))
      (if (re-search-forward (concat "^" (regexp-quote key) ":.*$") limit t)
          (replace-match (format "%s: %s" key value) t t)
        (goto-char (point-min))
        ;; Skip past any existing #+keyword lines in org files.
        (while (and (not (eobp)) (looking-at "^[#@,]"))
          (forward-line 1))
        (insert (format "%s: %s\n" key value))))))

(defun autoslip-howm--delete-header-property (key)
  "Remove the top-of-file header KEY line, if any."
  (save-excursion
    (goto-char (point-min))
    (let ((limit (save-excursion (forward-line 60) (point))))
      (when (re-search-forward
             (concat "^" (regexp-quote key) ":.*\n")
             limit t)
        (replace-match "")))))

(defun autoslip-howm--children-property-keywords ()
  "Return the list of child keywords stored in the children property."
  (let ((raw (autoslip-howm--get-header-property
              autoslip-howm-children-property)))
    (when raw
      (split-string raw "[ ,]+" t))))

(defun autoslip-howm--set-children-property-keywords (keywords)
  "Write KEYWORDS into the children header property."
  (if keywords
      (autoslip-howm--set-header-property
       autoslip-howm-children-property
       (string-join (delete-dups (copy-sequence keywords)) ", "))
    (autoslip-howm--delete-header-property
     autoslip-howm-children-property)))

(defun autoslip-howm--insert-backlink-headers (parent-keyword)
  "Write a reference to PARENT-KEYWORD in the current buffer using `headers' mode."
  (autoslip-howm--set-header-property
   autoslip-howm-parent-property parent-keyword))

(defun autoslip-howm--insert-backlink (parent-keyword)
  "Dispatch on `autoslip-howm-link-storage' for PARENT-KEYWORD."
  (pcase autoslip-howm-link-storage
    ('headers (autoslip-howm--insert-backlink-headers parent-keyword))
    (_        (autoslip-howm--insert-backlink-headings parent-keyword))))

(defun autoslip-howm--render-forward-link-entry (child-keyword target-file)
  "Return a heading-and-goto block for CHILD-KEYWORD as a string.
The block is a level-3 heading carrying the child's full title
\(address plus title) followed by a goto-link to CHILD-KEYWORD on
the next line.  When the child's title cannot be resolved from
the cache, the keyword's address segment is used in the heading.
TARGET-FILE picks `org-mode' versus plain-text heading style."
  (let* ((child (autoslip-howm--find-note-by-uid
                 (autoslip-howm--keyword-uid child-keyword)))
         (title (or (and child (plist-get child :title))
                    (autoslip-howm--keyword-address child-keyword))))
    (concat (autoslip-howm--format-heading title 3 target-file)
            "\n"
            (autoslip-howm--goto-line child-keyword))))

(defun autoslip-howm--insert-forward-link-headings (child-keyword parent-file)
  "Append a Child Notes entry for CHILD-KEYWORD into PARENT-FILE.
The entry is a level-3 heading carrying the child's full title,
followed by a goto-link on the line below.  Entries inserted at
different times accumulate in reverse-insertion order; call
`autoslip-howm-rebuild-child-notes' on the parent to re-sort."
  (with-current-buffer (find-file-noselect parent-file)
    (autoslip-howm--insert-under-heading
     autoslip-howm-forward-link-heading
     (autoslip-howm--render-forward-link-entry
      child-keyword parent-file))
    (save-buffer)))

(defun autoslip-howm--insert-forward-link-headers (child-keyword parent-file)
  "Add CHILD-KEYWORD to PARENT-FILE's children header property."
  (with-current-buffer (find-file-noselect parent-file)
    (let* ((existing (autoslip-howm--children-property-keywords))
           (merged (if (member child-keyword existing)
                       existing
                     (append existing (list child-keyword)))))
      (autoslip-howm--set-children-property-keywords merged))
    (save-buffer)))

(defun autoslip-howm--insert-forward-link (child-keyword parent-file)
  "Dispatch on storage mode for CHILD-KEYWORD into PARENT-FILE."
  (pcase autoslip-howm-link-storage
    ('headers (autoslip-howm--insert-forward-link-headers child-keyword parent-file))
    (_        (autoslip-howm--insert-forward-link-headings child-keyword parent-file))))


;;; ============================================================================
;;; Note creation
;;; ============================================================================

(defun autoslip-howm--initial-content (address title parent-keyword
                                                target-file)
  "Return the starting text for a new note.
ADDRESS is the folgezettel; TITLE is the human-readable title;
PARENT-KEYWORD is the parent's wiki keyword (nil for a root note);
TARGET-FILE is the path the file will be written to, used to choose
`org-mode' versus plain-text heading style."
  (let* ((uid (autoslip-howm--mint-uid))
         (self-kw (autoslip-howm--make-keyword address uid))
         (display-title (format "%s %s" address (or title "")))
         (lines (list display-title)))
    (when autoslip-howm-self-anchor
      (push (string-trim-right (autoslip-howm--anchor-line self-kw))
            lines)
      (push "" lines))
    (when parent-keyword
      (pcase autoslip-howm-link-storage
        ('headers
         (push (format "%s: %s"
                       autoslip-howm-parent-property
                       parent-keyword)
               lines))
        (_
         (push "" lines)
         (push (autoslip-howm--format-heading
                autoslip-howm-backlink-heading 2
                target-file)
               lines)
         (push (string-trim-right
                (autoslip-howm--goto-line parent-keyword))
               lines))))
    (concat (mapconcat #'identity (reverse lines) "\n") "\n")))

;;;###autoload
(defun autoslip-howm-create-note (address title)
  "Create a new howm note with ADDRESS and TITLE.
Writes a self-anchor line, sets up the parent backlink when a parent
exists, writes a forward link in the parent, and returns the new
keyword.

When called interactively, prompts for ADDRESS and TITLE.  This is
the right command for creating a root note (\"1.\", \"2.\", etc.)
or any note whose parent you do not have open.  For child notes
under the current note, prefer `autoslip-howm-insert-next-child',
which suggests the next available address.

This is the workhorse used by `autoslip-howm-insert-next-child'."
  (interactive
   (list (read-string "Folgezettel address: ")
         (read-string "Title: ")))
  (autoslip-howm--maybe-rescan)
  (let* ((errors (autoslip-howm-validate-address-full address)))
    (when errors
      (user-error "Invalid address '%s': %s"
                  address (string-join errors "; "))))
  (when (autoslip-howm--find-note-by-address address)
    (user-error "Address '%s' is already in use" address))
  (let* ((parent-addr (autoslip-howm--parse-address address))
         (parent (and parent-addr
                      (autoslip-howm--find-note-by-address parent-addr)))
         (parent-keyword (and parent (plist-get parent :keyword)))
         (file (autoslip-howm--filename-for address title))
         (initial (autoslip-howm--initial-content
                   address title parent-keyword file)))
    (when (file-exists-p file)
      (user-error "File already exists: %s" file))
    (unless (file-directory-p autoslip-howm-directory)
      (make-directory autoslip-howm-directory t))
    (with-temp-file file (insert initial))
    (let ((self-kw (autoslip-howm--read-self-keyword file)))
      (when (and parent self-kw)
        (autoslip-howm--insert-forward-link
         self-kw (plist-get parent :file)))
      (autoslip-howm-rescan)
      (find-file file)
      self-kw)))


;;; ============================================================================
;;; Interactive commands
;;; ============================================================================

;;;###autoload
(defun autoslip-howm-insert-next-child ()
  "Create a child note of the note at point, with bidirectional links."
  (interactive)
  (autoslip-howm--maybe-rescan)
  (let* ((note (autoslip-howm--find-note-at-point))
         (current-fz (and note (plist-get note :address))))
    (unless current-fz
      (user-error "Current buffer has no folgezettel-indexed note"))
    (let* ((suggestions (autoslip-howm-suggest-next-child current-fz)))
      (if (null suggestions)
          (user-error "Could not generate a suggestion for '%s'" current-fz)
        (let* ((choice (completing-read
                        (format "Child address (parent %s): " current-fz)
                        suggestions nil nil nil nil (car suggestions)))
               (errors (autoslip-howm-validate-new-child current-fz choice)))
          (cond
           (errors
            (user-error "%s" (string-join errors "; ")))
           ((not (autoslip-howm-check-duplicate-index choice))
            (user-error "Address '%s' is already in use" choice))
           (t
            (let* ((title (read-string (format "Title for %s: " choice))))
              (autoslip-howm-create-note choice title)
              (message "Created child note %s" choice)))))))))

;;;###autoload
(defun autoslip-howm-add-backlink-to-parent ()
  "Manually add bidirectional links between the current note and its parent."
  (interactive)
  (autoslip-howm--maybe-rescan)
  (let* ((note (autoslip-howm--find-note-at-point))
         (fz (and note (plist-get note :address))))
    (unless fz
      (user-error "Current buffer has no folgezettel-indexed note"))
    (let* ((parent-addr (autoslip-howm--parse-address fz))
           (parent (and parent-addr
                        (autoslip-howm--find-note-by-address parent-addr))))
      (cond
       ((not parent-addr)
        (user-error "Note %s is a root note" fz))
       ((not parent)
        (user-error "No note found for parent address %s" parent-addr))
       (t
        (let* ((parent-kw (plist-get parent :keyword))
               (self-kw (or (plist-get note :keyword)
                            (autoslip-howm--ensure-self-anchor fz))))
          (autoslip-howm--insert-backlink parent-kw)
          (save-buffer)
          (autoslip-howm--insert-forward-link
           self-kw (plist-get parent :file))
          (autoslip-howm-rescan)
          (message "Linked %s to parent %s" fz parent-addr)))))))

;;;###autoload
(defun autoslip-howm-goto-parent ()
  "Visit the parent note of the current note."
  (interactive)
  (autoslip-howm--maybe-rescan)
  (let* ((note (autoslip-howm--find-note-at-point))
         (fz (and note (plist-get note :address)))
         (parent-addr (and fz (autoslip-howm--parse-address fz))))
    (cond
     ((not fz)
      (user-error "Current buffer has no folgezettel-indexed note"))
     ((not parent-addr)
      (user-error "Note %s is a root note" fz))
     (t
      (let ((parent (autoslip-howm--find-note-by-address parent-addr)))
        (if parent
            (find-file (plist-get parent :file))
          (user-error "No note found for parent address %s" parent-addr)))))))

;;;###autoload
(defun autoslip-howm-list-children ()
  "Pick a direct child of the current note and visit it."
  (interactive)
  (autoslip-howm--maybe-rescan)
  (let* ((note (autoslip-howm--find-note-at-point))
         (fz (and note (plist-get note :address))))
    (unless fz
      (user-error "Current buffer has no folgezettel-indexed note"))
    (let* ((children (autoslip-howm--children-notes-of fz))
           (sorted (sort (copy-sequence children)
                         (lambda (a b)
                           (autoslip-howm--compare-addresses
                            (plist-get a :address)
                            (plist-get b :address))))))
      (if (null sorted)
          (message "%s has no children" fz)
        (let* ((alist (mapcar (lambda (c)
                                (cons (or (plist-get c :title)
                                          (plist-get c :address))
                                      c))
                              sorted))
               (choice (completing-read
                        (format "Children of %s: " fz)
                        (mapcar #'car alist) nil t)))
          (find-file (plist-get (cdr (assoc choice alist)) :file)))))))

;;;###autoload
(defun autoslip-howm-show-tree ()
  "Display every folgezettel-indexed note in a tree buffer."
  (interactive)
  (autoslip-howm--maybe-rescan)
  (let* ((notes (seq-filter (lambda (n) (plist-get n :address))
                            (autoslip-howm--all-notes)))
         (sorted (sort (copy-sequence notes)
                       (lambda (a b)
                         (autoslip-howm--compare-addresses
                          (plist-get a :address)
                          (plist-get b :address)))))
         (buf (get-buffer-create "*Autoslip-Howm Tree*")))
    (with-current-buffer buf
      (let ((inhibit-read-only t))
        (erase-buffer)
        (special-mode)
        (insert "Autoslip-Howm Tree\n")
        (insert (make-string 60 ?=) "\n\n")
        (if (null sorted)
            (insert "No folgezettel-indexed notes found.\n")
          (dolist (n sorted)
            (let* ((addr (plist-get n :address))
                   (title (plist-get n :title))
                   (file (plist-get n :file))
                   (depth (autoslip-howm--address-depth addr))
                   (start (point)))
              (insert (make-string (* 2 depth) ?\s))
              (insert-text-button
               (or title addr)
               'follow-link t
               'action (lambda (_) (find-file file)))
              (insert "\n")
              (put-text-property start (point) 'autoslip-howm-file file))))
        (goto-char (point-min))))
    (switch-to-buffer-other-window buf)))


;;; ============================================================================
;;; Index of Indices
;;; ============================================================================

(defun autoslip-howm--root-notes ()
  "Return the cached note plists whose address is a root.
Sorted in canonical folgezettel order."
  (autoslip-howm--maybe-rescan)
  (let* ((roots (seq-filter
                 (lambda (n)
                   (let ((a (plist-get n :address)))
                     (and a (autoslip-howm--root-address-p a))))
                 (autoslip-howm--all-notes))))
    (sort (copy-sequence roots)
          (lambda (a b)
            (autoslip-howm--compare-addresses
             (plist-get a :address)
             (plist-get b :address))))))

(defun autoslip-howm--root-list-as-text (target-file)
  "Return the root list rendered as a heading block for TARGET-FILE.
TARGET-FILE picks `org-mode' versus plain-text heading style."
  (with-temp-buffer
    (dolist (n (autoslip-howm--root-notes))
      (let ((addr  (plist-get n :address))
            (title (plist-get n :title))
            (kw    (plist-get n :keyword)))
        (insert (autoslip-howm--format-heading
                 (or title addr) 2 target-file)
                "\n")
        (when kw
          (insert (autoslip-howm--goto-line kw)))
        (insert "\n")))
    (buffer-string)))

;;;###autoload
(defun autoslip-howm-insert-root-list ()
  "Insert the current set of roots at point as a sorted heading block.
Each root becomes a level-2 heading.  When the root carries a wiki
keyword, a goto-link to that keyword appears on the line below the
heading.  Heading style adapts to the file flavor (org-mode versus
plain-text howm).  This is the primary helper for keeping the index
of indices in sync as new roots are minted."
  (interactive)
  (unless (bolp) (insert "\n"))
  (insert (autoslip-howm--root-list-as-text buffer-file-name))
  (let ((count (length (autoslip-howm--root-notes))))
    (message "Inserted %d root%s" count (if (= count 1) "" "s"))))

;;;###autoload
(defun autoslip-howm-open-index ()
  "Visit the index-of-indices file, creating it if it does not yet exist.
The file is named by `autoslip-howm-index-file-name' and lives in
`autoslip-howm-directory'.  When created, the file is seeded with a
title line, a self-anchor with a fresh UID, a top-level heading, and
the current root list."
  (interactive)
  (autoslip-howm--maybe-rescan)
  (let* ((file (expand-file-name autoslip-howm-index-file-name
                                 autoslip-howm-directory))
         (existed (file-exists-p file)))
    (unless (file-directory-p autoslip-howm-directory)
      (make-directory autoslip-howm-directory t))
    (unless existed
      (let* ((uid (autoslip-howm--mint-uid))
             (kw  (autoslip-howm--make-keyword "00." uid))
             (heading (autoslip-howm--format-heading
                       "Roots in this zettelkasten" 1 file)))
        (with-temp-file file
          (insert "00. Index of Indices\n")
          (insert (autoslip-howm--anchor-line kw))
          (insert "\n")
          (insert heading "\n\n")
          (insert (autoslip-howm--root-list-as-text file)))))
    (find-file file)
    (autoslip-howm-rescan)
    (when existed
      (message "Opened existing index at %s" file))))


;;; ============================================================================
;;; Hub and topic indexes
;;; ============================================================================
;;
;; Two index shapes are supported.  A HUB INDEX lists only the direct
;; children of the current note and is meant for the start or for a
;; branching point of a chain of thought.  A TOPIC INDEX lists every
;; note whose body matches a regex, which lets it span parallel chains
;; of thought.  The two use distinguishable wrapper headings so a
;; reader can tell at a glance which one they are looking at.

(defun autoslip-howm--resolve-search-backend ()
  "Return the search backend symbol that should be used now.
Honors `autoslip-howm-search-backend'.  When that is `auto', picks
the first available of rg, grep, in-Emacs scan."
  (pcase autoslip-howm-search-backend
    ('auto
     (cond
      ((executable-find autoslip-howm-rg-program) 'rg)
      ((executable-find autoslip-howm-grep-program) 'grep)
      (t 'emacs)))
    ((or 'rg 'grep 'emacs) autoslip-howm-search-backend)
    (_ 'emacs)))

(defun autoslip-howm--search-files-via-rg (regex)
  "Return absolute file paths under `autoslip-howm-directory' matching REGEX.
Shells out to ripgrep; expects `autoslip-howm-rg-program' on PATH.
The regex flavor is rg's default (Rust regex syntax)."
  (let ((dir (expand-file-name autoslip-howm-directory)))
    (with-temp-buffer
      (let ((status
             (call-process
              autoslip-howm-rg-program nil t nil
              "--files-with-matches"
              "--no-messages"
              "--null"
              "-e" regex
              "--" dir)))
        (cond
         ((= status 0) (split-string (buffer-string) "\0" t))
         ((= status 1) nil)              ; no matches; not an error
         (t (error "Ripgrep failed (exit %s): %s"
                   status (buffer-string))))))))

(defun autoslip-howm--search-files-via-grep (regex)
  "Return absolute file paths under `autoslip-howm-directory' matching REGEX.
Shells out to grep with -E (ERE flavor).  Splits output on newlines,
which is portable across GNU and BSD grep but assumes file names do
not contain newlines."
  (let ((dir (expand-file-name autoslip-howm-directory)))
    (with-temp-buffer
      (let ((status
             (call-process
              autoslip-howm-grep-program nil t nil
              "-r" "-l" "-E"
              "-e" regex
              "--" dir)))
        (cond
         ((= status 0) (split-string (buffer-string) "\n" t))
         ((= status 1) nil)
         (t (error "Grep failed (exit %s): %s"
                   status (buffer-string))))))))

(defun autoslip-howm--search-files-via-emacs (regex)
  "Return absolute file paths under `autoslip-howm-directory' matching REGEX.
Reads each cached note in a temp buffer and runs `re-search-forward'.
Slowest of the three backends but always available."
  (autoslip-howm--maybe-rescan)
  (let (matches)
    (dolist (n (autoslip-howm--all-notes))
      (let ((file (plist-get n :file)))
        (with-temp-buffer
          (condition-case _
              (insert-file-contents file)
            (error nil))
          (goto-char (point-min))
          (when (re-search-forward regex nil t)
            (push file matches)))))
    (nreverse matches)))

(defun autoslip-howm--map-files-to-notes (files)
  "Return cached note plists for FILES, sorted in folgezettel order.
Files not present in the cache are dropped, which filters out hits
inside `.git', backups, and any non-howm clutter under the howm
directory."
  (autoslip-howm--maybe-rescan)
  (let ((by-file (make-hash-table :test 'equal)))
    (dolist (n (autoslip-howm--all-notes))
      (puthash (expand-file-name (plist-get n :file)) n by-file))
    (sort
     (delq nil
           (mapcar (lambda (f) (gethash (expand-file-name f) by-file))
                   files))
     (lambda (a b)
       (autoslip-howm--compare-addresses
        (or (plist-get a :address) "")
        (or (plist-get b :address) ""))))))

(defun autoslip-howm--search-notes-by-regex (regex)
  "Return the cached notes whose file content matches REGEX.
Dispatches to the backend selected by
`autoslip-howm-search-backend'.  See that variable's docstring for
the regex-flavor caveat.  Returns the matching note plists in
folgezettel order."
  (autoslip-howm--maybe-rescan)
  (let* ((backend (autoslip-howm--resolve-search-backend))
         (files
          (pcase backend
            ('rg    (autoslip-howm--search-files-via-rg regex))
            ('grep  (autoslip-howm--search-files-via-grep regex))
            (_      (autoslip-howm--search-files-via-emacs regex)))))
    (autoslip-howm--map-files-to-notes files)))

(defun autoslip-howm--render-index-block (notes heading-text target-file)
  "Return NOTES rendered as a wrapper-headed index block.
HEADING-TEXT becomes a level-2 heading.  Each entry under it is a
level-3 heading whose line is followed by a goto-link to the
note's wiki keyword.  TARGET-FILE picks `org-mode' versus
plain-text heading style."
  (with-temp-buffer
    (insert (autoslip-howm--format-heading heading-text 2 target-file)
            "\n\n")
    (if (null notes)
        (insert "(No matching notes.)\n")
      (dolist (n notes)
        (let ((title (or (plist-get n :title)
                         (plist-get n :address)))
              (kw (plist-get n :keyword)))
          (insert (autoslip-howm--format-heading title 3 target-file)
                  "\n")
          (when kw
            (insert (autoslip-howm--goto-line kw)))
          (insert "\n"))))
    (buffer-string)))

;;;###autoload
(defun autoslip-howm-insert-hub-index ()
  "Insert at point an index of the direct children of the current note.
Each child becomes a level-3 heading with a goto-link.  The block
is wrapped in a level-2 heading whose text comes from
`autoslip-howm-hub-index-heading-format'.

Use this at the top of a hub note, or at any branching point in a
chain of thought, to give the reader a one-screen overview of the
direct descendants without the rest of the subtree.  Grandchildren
are intentionally not included; this index documents one tier of
descent only.  For cross-references that span chains of thought,
use `autoslip-howm-insert-topic-index' instead."
  (interactive)
  (autoslip-howm--maybe-rescan)
  (let* ((note (autoslip-howm--find-note-at-point))
         (fz (and note (plist-get note :address))))
    (unless fz
      (user-error "Current buffer has no folgezettel-indexed note"))
    (let* ((children (autoslip-howm--children-notes-of fz))
           (sorted (sort (copy-sequence children)
                         (lambda (a b)
                           (autoslip-howm--compare-addresses
                            (plist-get a :address)
                            (plist-get b :address)))))
           (heading (format autoslip-howm-hub-index-heading-format fz)))
      (unless (bolp) (insert "\n"))
      (insert (autoslip-howm--render-index-block
               sorted heading buffer-file-name))
      (message "Inserted hub index for %s (%d direct child%s)"
               fz (length sorted)
               (if (= (length sorted) 1) "" "ren")))))

;;;###autoload
(defun autoslip-howm-insert-topic-index (search-term)
  "Insert at point a topic index of every note matching SEARCH-TERM.
SEARCH-TERM is treated as a regular expression and matched against
the full text of every note in the vault.  Each matching note
becomes a level-3 heading with a goto-link.  The block is wrapped
in a level-2 heading whose text comes from
`autoslip-howm-topic-index-heading-format'.

Topic indexes are designed for cross-references that span chains
of thought; they intentionally use a different wrapper heading
than `autoslip-howm-insert-hub-index' so a reader can tell the
two index shapes apart at a glance.

The current note is excluded from the result, even when its body
matches the search term, because a self-reference adds nothing to
the index."
  (interactive (list (read-string "Topic search term (regexp): ")))
  (when (string-empty-p search-term)
    (user-error "Search term must be non-empty"))
  (autoslip-howm--maybe-rescan)
  (let* ((self (autoslip-howm--find-note-at-point))
         (self-file (and self (plist-get self :file)))
         (matches (autoslip-howm--search-notes-by-regex search-term))
         (filtered (seq-filter
                    (lambda (n)
                      (not (and self-file
                                (string= (plist-get n :file) self-file))))
                    matches))
         (heading (format autoslip-howm-topic-index-heading-format
                          search-term)))
    (unless (bolp) (insert "\n"))
    (insert (autoslip-howm--render-index-block
             filtered heading buffer-file-name))
    (message "Inserted topic index for %S (%d match%s)"
             search-term (length filtered)
             (if (= (length filtered) 1) "" "es"))))


;;; ============================================================================
;;; Obsidian import
;;; ============================================================================

(defun autoslip-howm--parse-obsidian-index (file)
  "Parse Obsidian markdown FILE and return a list of entry plists.
Each entry is a plist with :number (integer), :title (string),
and :section (`knowledge' or `project').  The split is detected by
`autoslip-howm-obsidian-project-heading-regexp'.  Lines that do not
match the markdown link pattern are skipped silently."
  (with-temp-buffer
    (insert-file-contents file)
    (goto-char (point-min))
    (let ((section 'knowledge)
          (entries '())
          (link-pat
           "^[ \t]*\\[\\([0-9]+\\)\\.[ \t]+\\([^]]+?\\)\\][ \t]*("))
      (while (not (eobp))
        (cond
         ((looking-at autoslip-howm-obsidian-project-heading-regexp)
          (setq section 'project))
         ((looking-at link-pat)
          (push (list :number (string-to-number (match-string 1))
                      :title  (string-trim (match-string 2))
                      :section section)
                entries)))
        (forward-line 1))
      (nreverse entries))))

(defun autoslip-howm--remap-obsidian-entries (entries offset)
  "Return ENTRIES with OFFSET added to the :number of every project entry."
  (mapcar
   (lambda (e)
     (if (eq (plist-get e :section) 'project)
         (list :number (+ (plist-get e :number) offset)
               :title  (plist-get e :title)
               :section 'project)
       e))
   entries))

(defun autoslip-howm--obsidian-entries-as-pairs (entries)
  "Return ENTRIES as a list of (ADDRESS . TITLE) cons pairs."
  (mapcar
   (lambda (e)
     (cons (format "%d." (plist-get e :number))
           (plist-get e :title)))
   entries))

(defun autoslip-howm--rename-note-title-line (note new-display-title)
  "In NOTE's file, replace the first non-empty line with NEW-DISPLAY-TITLE.
Any howm or org title marker on that line is preserved.
NEW-DISPLAY-TITLE should already contain the leading folgezettel."
  (let ((file (plist-get note :file)))
    (with-current-buffer (find-file-noselect file)
      (save-excursion
        (goto-char (point-min))
        (while (and (not (eobp))
                    (looking-at "^[ \t]*$"))
          (forward-line 1))
        (unless (eobp)
          (let* ((bol (line-beginning-position))
                 (eol (line-end-position))
                 (line (buffer-substring-no-properties bol eol))
                 (prefix
                  (cond
                   ((string-match "\\`#\\+[Tt][Ii][Tt][Ll][Ee]:[ \t]*" line)
                    (match-string 0 line))
                   ((string-match "\\`= " line) "= ")
                   ((string-match "\\`,[ \t]*M[ \t]+" line) ",M ")
                   ((string-match "\\`,[ \t]+" line) ", ")
                   (t ""))))
            (delete-region bol eol)
            (insert prefix new-display-title))))
      (save-buffer))))

(defun autoslip-howm--write-index-file (file)
  "Write or rewrite the index-of-indices FILE from the current root list.
Preserves an existing self-keyword UID when present; otherwise mints
a fresh UID for the new index file.

When a buffer is currently visiting FILE, replace that buffer's
contents and save through the buffer.  This keeps the visible
buffer and the on-disk file in sync, and prevents a stale buffer
from later overwriting the freshly written file via a manual save."
  (let* ((existing-kw (and (file-exists-p file)
                           (autoslip-howm--read-self-keyword file)))
         (kw (or existing-kw
                 (autoslip-howm--make-keyword
                  "00." (autoslip-howm--mint-uid))))
         (heading (autoslip-howm--format-heading
                   "Roots in this zettelkasten" 1 file))
         (content
          (with-temp-buffer
            (insert "00. Index of Indices\n")
            (insert (autoslip-howm--anchor-line kw))
            (insert "\n")
            (insert heading "\n\n")
            (insert (autoslip-howm--root-list-as-text file))
            (buffer-string)))
         (visiting (get-file-buffer file)))
    (cond
     (visiting
      (with-current-buffer visiting
        (let ((inhibit-read-only t))
          (erase-buffer)
          (insert content))
        (save-buffer)))
     (t
      (with-temp-file file
        (insert content))))
    file))

(defun autoslip-howm--title-slug (title)
  "Return a slug for TITLE after stripping any leading folgezettel.
Returns nil when TITLE is nil, empty, or reduces to nothing once
the leading folgezettel is stripped."
  (when (and title (not (string-empty-p title)))
    (let ((stripped
           (replace-regexp-in-string
            "\\`[0-9]+\\(?:\\.[0-9a-z]*\\)?[ \t]+"
            "" title)))
      (when (and stripped (not (string-empty-p stripped)))
        (autoslip-howm--slugify stripped)))))

(defun autoslip-howm--find-note-by-title-slug (slug &optional exclude-files)
  "Return a cached note whose title slug equals SLUG, or nil.
EXCLUDE-FILES, if non-nil, is a hash table whose keys are absolute
file paths to skip during the search."
  (when (and slug (not (string-empty-p slug)))
    (seq-find
     (lambda (n)
       (let* ((nf (expand-file-name (or (plist-get n :file) "")))
              (ns (autoslip-howm--title-slug (plist-get n :title))))
         (and ns
              (string= ns slug)
              (or (null exclude-files)
                  (not (gethash nf exclude-files))))))
     (autoslip-howm--all-notes))))

(defun autoslip-howm--adopt-file (file address title)
  "Adopt an existing FILE as the note for ADDRESS and TITLE.
Ensures the file's first non-empty line reads \"ADDRESS TITLE\" and
that a self-anchor for ADDRESS is in place.  The body of the file is
otherwise preserved.  Returns the resulting wiki keyword string."
  (with-current-buffer (find-file-noselect file)
    (let ((display (format "%s %s" address title)))
      (cond
       ((= (point-min) (point-max))
        (goto-char (point-min))
        (insert display "\n"))
       (t
        (let* ((line (save-excursion
                       (goto-char (point-min))
                       (while (and (not (eobp))
                                   (looking-at "^[ \t]*$"))
                         (forward-line 1))
                       (and (not (eobp))
                            (buffer-substring-no-properties
                             (line-beginning-position)
                             (line-end-position)))))
               (current (and line (autoslip-howm--strip-title-marker line))))
          (unless (and current (string= current display))
            (autoslip-howm--rename-note-title-line
             (list :file file) display))))))
    (autoslip-howm--ensure-self-anchor address)
    (save-buffer))
  (autoslip-howm-rescan)
  (autoslip-howm--read-self-keyword file))

(defun autoslip-howm--renumber-note (note new-addr new-title)
  "Renumber NOTE to live at NEW-ADDR with NEW-TITLE.
Rewrites the title line, the self-anchor (when one exists),
inbound keyword references across the vault, and the file name (when
the original address is known)."
  (let* ((file (plist-get note :file))
         (old-addr (plist-get note :address))
         (old-kw (plist-get note :keyword))
         (old-uid (and old-kw (autoslip-howm--keyword-uid old-kw)))
         (display (format "%s %s" new-addr new-title)))
    (with-current-buffer (find-file-noselect file)
      (autoslip-howm--rename-note-title-line note display)
      (when old-addr
        (autoslip-howm--rewrite-anchor-line old-addr new-addr))
      (autoslip-howm--ensure-self-anchor new-addr)
      (save-buffer)
      (when (and old-addr autoslip-howm-rename-files-on-reparent)
        (let ((new-file (autoslip-howm--rename-note-file
                         file old-addr new-addr)))
          (when new-file
            (set-visited-file-name new-file nil t)
            (set-buffer-modified-p nil)))))
    (when (and old-uid old-addr)
      (autoslip-howm--rewrite-inbound-keyword old-uid old-addr new-addr))
    (autoslip-howm-rescan)))

(defun autoslip-howm--reconcile-entry (addr title master consumed)
  "Reconcile one (ADDR . TITLE) entry against the Howm vault.
MASTER is `obsidian' or `howm'.  CONSUMED is a hash table whose
keys are absolute file paths already used in the current run; the
function adds the path it touches.

Returns one of the symbols `unchanged', `renamed', `renumbered',
`adopted', `created' to indicate the outcome."
  (let* ((display (format "%s %s" addr title))
         (slug (autoslip-howm--title-slug display))
         (existing (autoslip-howm--find-note-by-address addr))
         (by-title (unless existing
                     (autoslip-howm--find-note-by-title-slug
                      slug consumed)))
         (dest-file (autoslip-howm--filename-for addr title)))
    (cond
     ;; (1) Address match.
     (existing
      (puthash (expand-file-name (plist-get existing :file)) t consumed)
      (cond
       ((string= (or (plist-get existing :title) "") display) 'unchanged)
       ((eq master 'obsidian)
        (autoslip-howm--rename-note-title-line existing display)
        'renamed)
       (t 'unchanged)))
     ;; (2) Title match at a different address (or no address).
     (by-title
      (puthash (expand-file-name (plist-get by-title :file)) t consumed)
      (cond
       ((eq master 'obsidian)
        (autoslip-howm--renumber-note by-title addr title)
        'renumbered)
       (t 'unchanged)))
     ;; (3) Destination file exists on disk but the cache cannot
     ;; associate it with the address.
     ((file-exists-p dest-file)
      (puthash (expand-file-name dest-file) t consumed)
      (autoslip-howm--adopt-file dest-file addr title)
      'adopted)
     ;; (4) Truly missing: mint a new note.
     (t
      (autoslip-howm-create-note addr title)
      (puthash (expand-file-name dest-file) t consumed)
      'created))))

(defun autoslip-howm--has-link-to (keyword)
  "Return non-nil when the current buffer would contain a literal KEYWORD."
  (when (and keyword (not (string-empty-p keyword)))
    (save-excursion
      (goto-char (point-min))
      (re-search-forward (regexp-quote keyword) nil t))))

(defun autoslip-howm--ensure-bidirectional-link (child parent)
  "Ensure CHILD has a parent backlink to PARENT and PARENT has a forward link.
CHILD and PARENT are cached note plists.  Both link insertions are
skipped when the destination buffer already contains a literal
copy of the target keyword, which makes the function idempotent."
  (let ((child-file (plist-get child :file))
        (child-kw (plist-get child :keyword))
        (parent-file (plist-get parent :file))
        (parent-kw (plist-get parent :keyword)))
    (when (and child-file child-kw parent-file parent-kw)
      (with-current-buffer (find-file-noselect child-file)
        (unless (autoslip-howm--has-link-to parent-kw)
          (autoslip-howm--insert-backlink parent-kw)
          (save-buffer)))
      (with-current-buffer (find-file-noselect parent-file)
        (unless (autoslip-howm--has-link-to child-kw)
          (autoslip-howm--insert-forward-link child-kw parent-file))))))

(defun autoslip-howm--remove-section (heading)
  "Remove the HEADING section, with its content, from the current buffer.
HEADING is the text of the section heading (without the leading
stars).  The section is delimited by the next heading of the same
or shallower level, or by end of buffer.  Returns the buffer
position where the section started, or nil when no such section
exists."
  (when (and heading (not (string-empty-p heading)))
    (save-excursion
      (goto-char (point-min))
      (let ((pat (concat "^\\(\\*+\\) "
                         (regexp-quote heading)
                         "[ \t]*$")))
        (when (re-search-forward pat nil t)
          (let* ((heading-start (match-beginning 0))
                 (heading-level (length (match-string 1)))
                 (section-end
                  (save-excursion
                    (forward-line 1)
                    (if (re-search-forward
                         (format "^\\*\\{1,%d\\} " heading-level)
                         nil t)
                        (match-beginning 0)
                      (point-max)))))
            (delete-region heading-start section-end)
            heading-start))))))

(defun autoslip-howm--rebuild-child-notes-of (parent-note)
  "Rewrite the Child Notes section of PARENT-NOTE from cache.
Every direct child of PARENT-NOTE becomes a level-3 heading
containing the child's full title (address plus title), followed
by a goto-link to the child's keyword.  Entries are sorted by
folgezettel.  When the parent has no children, the Child Notes
section is removed entirely."
  (let* ((file (plist-get parent-note :file))
         (fz (plist-get parent-note :address)))
    (when (and file fz autoslip-howm-forward-link-heading
               (eq autoslip-howm-link-storage 'headings))
      (let* ((children (autoslip-howm--children-notes-of fz))
             (sorted (sort (copy-sequence children)
                           (lambda (a b)
                             (autoslip-howm--compare-addresses
                              (plist-get a :address)
                              (plist-get b :address))))))
        (with-current-buffer (find-file-noselect file)
          (let ((pos (autoslip-howm--remove-section
                      autoslip-howm-forward-link-heading)))
            (when sorted
              (save-excursion
                (cond
                 (pos (goto-char pos))
                 (t (goto-char (point-max))
                    (unless (bolp) (insert "\n"))
                    (insert "\n")))
                (insert (autoslip-howm--format-heading
                         autoslip-howm-forward-link-heading 2 file)
                        "\n\n")
                (dolist (n sorted)
                  (insert (autoslip-howm--render-forward-link-entry
                           (plist-get n :keyword) file)
                          "\n")))))
          (save-buffer))))))

;;;###autoload
(defun autoslip-howm-rebuild-child-notes ()
  "Replace the Child Notes section in the current note with a fresh listing.
Every direct child of the current note is rendered as a level-3
heading containing the child's full title, followed by a goto-link
to the child's keyword.  Existing content under the Child Notes
heading is discarded.  When the current note has no children, the
Child Notes section is removed.

Use this command to upgrade parent files that were written by
older versions of the package, where forward links were bare
goto-lines without title headings."
  (interactive)
  (autoslip-howm--maybe-rescan)
  (let* ((note (autoslip-howm--find-note-at-point))
         (fz (and note (plist-get note :address))))
    (unless fz
      (user-error "Current buffer has no folgezettel-indexed note"))
    (autoslip-howm--rebuild-child-notes-of note)
    (let ((count (length (autoslip-howm--children-notes-of fz))))
      (message "Rebuilt Child Notes for %s (%d child%s)"
               fz count
               (if (= count 1) "" "ren")))))

(defun autoslip-howm--ensure-master-link (note)
  "Ensure NOTE has an upward link to the 00. index-of-indices file.
Inserts a goto-link under `autoslip-howm-master-link-heading' when
the link is not already present anywhere in NOTE.  Does nothing
when no 00. note is in the cache."
  (let* ((index (autoslip-howm--find-note-by-address "00."))
         (index-kw (and index (plist-get index :keyword)))
         (file (plist-get note :file)))
    (when (and index-kw file
               (not (string= (expand-file-name file)
                             (expand-file-name (plist-get index :file)))))
      (with-current-buffer (find-file-noselect file)
        (unless (autoslip-howm--has-link-to index-kw)
          (if autoslip-howm-master-link-heading
              (autoslip-howm--insert-under-heading
               autoslip-howm-master-link-heading
               (autoslip-howm--goto-line index-kw))
            (save-excursion
              (goto-char (point-max))
              (unless (bolp) (insert "\n"))
              (insert (autoslip-howm--goto-line index-kw))))
          (save-buffer))))))

;;;###autoload
(defun autoslip-howm-add-master-link ()
  "Insert a link from the current note up to the 00. index of indices.
The link is added under the heading named by
`autoslip-howm-master-link-heading' (default \"Master Node\").  The
operation is idempotent: a second call on the same note is a no-op."
  (interactive)
  (autoslip-howm--maybe-rescan)
  (let ((note (autoslip-howm--find-note-at-point)))
    (unless note
      (user-error "Current buffer is not a tracked howm note"))
    (autoslip-howm--ensure-master-link note)
    (message "Master-node link ensured")))

(defun autoslip-howm--apply-obsidian-import (pairs master)
  "Apply imported PAIRS using MASTER (`obsidian' or `howm') strategy.
PAIRS is a list of (ADDRESS . TITLE).  The dispatch reuses existing
files whenever possible: an entry is matched first by address, then
by title slug across the cache, then by file presence at the
canonical destination path; only when none of those succeed is a
new note minted.

Each per-entry operation is wrapped in `condition-case', so a
single failing entry does not abort the rest of the run.  The
index-of-indices file is regenerated inside `unwind-protect',
which means it is rebuilt even when some entries fail and even
when an outer abort propagates.

Returns a plist with the counts :created, :renamed, :renumbered,
:adopted, :unchanged, plus :errors (list of (PAIR . MESSAGE))
and :index-file (the absolute path that was written)."
  (autoslip-howm--maybe-rescan)
  (let ((counters (make-hash-table :test 'eq))
        (errors '())
        (consumed (make-hash-table :test 'equal))
        (index-file (expand-file-name autoslip-howm-index-file-name
                                      autoslip-howm-directory)))
    (dolist (k '(unchanged renamed renumbered adopted created))
      (puthash k 0 counters))
    (unwind-protect
        (save-window-excursion
          (dolist (pair pairs)
            (condition-case err
                (let ((outcome (autoslip-howm--reconcile-entry
                                (car pair) (cdr pair) master consumed)))
                  (puthash outcome (1+ (gethash outcome counters 0))
                           counters))
              (error
               (push (cons pair (error-message-string err)) errors)))))
      ;; Always rebuild the cache and rewrite the index, even on abort.
      (ignore-errors (autoslip-howm-rescan))
      (ignore-errors (autoslip-howm--write-index-file index-file)))
    (list :created (gethash 'created counters 0)
          :renamed (gethash 'renamed counters 0)
          :renumbered (gethash 'renumbered counters 0)
          :adopted (gethash 'adopted counters 0)
          :unchanged (gethash 'unchanged counters 0)
          :errors (nreverse errors)
          :index-file index-file)))

;;;###autoload
(defun autoslip-howm-import-from-obsidian (markdown-file)
  "Import a 00. index of indices from Obsidian into the Howm vault.
MARKDOWN-FILE is the path to an Obsidian index file containing
markdown links of the form [N. Title](N.%20Title.md).  A heading
matching `autoslip-howm-obsidian-project-heading-regexp' splits the
file into a knowledge section and a project-support section.
Numbers in the project section are offset by
`autoslip-howm-obsidian-project-offset' (default 400, so Obsidian's
100, 101, 102 become Howm's 500, 501, 502).

For each imported entry, a Howm root note is created when no note
with the corresponding address already exists.

When the Howm directory already contains an index-of-indices file
named by `autoslip-howm-index-file-name', prompts whether the
imported (Obsidian) list or the existing (Howm) list should serve
as master.  In Obsidian-master mode, mismatched titles are rewritten
to match Obsidian.  In Howm-master mode, only new addresses are
created and existing titles stay.

The 00. file is regenerated at the end so its body lists every
current root in folgezettel order.  Hand-written annotations under
each root are not preserved; copy them aside before importing if
they matter."
  (interactive
   (list (read-file-name "Obsidian index file: " nil nil t)))
  (autoslip-howm--maybe-rescan)
  (let* ((entries (autoslip-howm--parse-obsidian-index markdown-file))
         (mapped (autoslip-howm--remap-obsidian-entries
                  entries autoslip-howm-obsidian-project-offset))
         (pairs (autoslip-howm--obsidian-entries-as-pairs mapped))
         (index-file (expand-file-name autoslip-howm-index-file-name
                                       autoslip-howm-directory))
         (master 'obsidian))
    (when (file-exists-p index-file)
      (let ((choice (completing-read
                     "An index already exists.  Master list: "
                     '("obsidian" "howm" "cancel")
                     nil t nil nil "obsidian")))
        (cond
         ((string= choice "cancel") (user-error "Import cancelled"))
         ((string= choice "howm") (setq master 'howm))
         (t (setq master 'obsidian)))))
    (let* ((result (autoslip-howm--apply-obsidian-import pairs master))
           (errs (plist-get result :errors))
           (path (plist-get result :index-file)))
      (when errs
        (with-output-to-temp-buffer "*Autoslip-Howm Import Errors*"
          (princ (format "%d entries failed during import:\n\n" (length errs)))
          (dolist (e errs)
            (princ (format "  %s -> %s\n    %s\n"
                           (car (car e))
                           (cdr (car e))
                           (cdr e))))))
      (message
       (concat "Imported %d entries to %s: "
               "%d created, %d renamed, %d renumbered, "
               "%d adopted, %d unchanged%s (master: %s)")
       (length pairs)
       path
       (plist-get result :created)
       (plist-get result :renamed)
       (plist-get result :renumbered)
       (plist-get result :adopted)
       (plist-get result :unchanged)
       (if errs (format ", %d ERRORS" (length errs)) "")
       master))))


;;; ============================================================================
;;; Importing children from Obsidian
;;; ============================================================================
;;
;; A separate command imports a markdown file that lists CHILDREN of
;; one parent note.  Both standard markdown links `[N.M Title](url)'
;; and Obsidian wikilinks `[[N.M Title]]' are accepted.  Entries whose
;; address does not lie under the supplied parent address are skipped
;; silently, so a master-node section in the file is harmless.
;;
;; After the per-entry reconciliation, each child gets a parent
;; backlink and the parent gets a forward link, both deduplicated.
;; The parent itself gets one upward link to the 00. index.

(defun autoslip-howm--parse-obsidian-children (file)
  "Parse FILE for child-note links.  Return a list of (ADDRESS . TITLE).
Both standard markdown links and Obsidian wikilinks are recognized.
Duplicate addresses are collapsed (the first occurrence wins)."
  (with-temp-buffer
    (insert-file-contents file)
    (goto-char (point-min))
    (let ((entries '())
          (seen (make-hash-table :test 'equal))
          (link-pat
           (concat
            "\\[\\[?"
            "\\([0-9]+\\(?:\\.[0-9a-z]*\\)?\\)"
            "[ \t]+"
            "\\([^]]+?\\)"
            "\\]\\]?")))
      (while (re-search-forward link-pat nil t)
        (let* ((addr-raw (match-string-no-properties 1))
               (title (string-trim (match-string-no-properties 2)))
               (addr (autoslip-howm--canonicalize-root addr-raw)))
          (unless (gethash addr seen)
            (puthash addr t seen)
            (push (cons addr title) entries))))
      (nreverse entries))))

(defun autoslip-howm--apply-children-import (pairs parent-address master)
  "Apply child PAIRS under PARENT-ADDRESS using MASTER strategy.
PAIRS is a list of (ADDRESS . TITLE).  Each entry runs through
`autoslip-howm--reconcile-entry'.  After the dispatch, each child
gets a parent backlink and the parent gets a forward link.  The
parent also gets an upward link to the 00. index.

Returns a plist with the same counters as
`autoslip-howm--apply-obsidian-import', plus :errors."
  (autoslip-howm--maybe-rescan)
  (let ((counters (make-hash-table :test 'eq))
        (errors '())
        (consumed (make-hash-table :test 'equal)))
    (dolist (k '(unchanged renamed renumbered adopted created))
      (puthash k 0 counters))
    (save-window-excursion
      (dolist (pair pairs)
        (condition-case err
            (let ((outcome (autoslip-howm--reconcile-entry
                            (car pair) (cdr pair) master consumed)))
              (puthash outcome (1+ (gethash outcome counters 0))
                       counters))
          (error
           (push (cons pair (error-message-string err)) errors)))))
    (autoslip-howm-rescan)
    (let ((parent (autoslip-howm--find-note-by-address parent-address)))
      (when parent
        (dolist (pair pairs)
          (condition-case err
              (let ((child (autoslip-howm--find-note-by-address
                            (car pair))))
                (when child
                  (autoslip-howm--ensure-bidirectional-link child parent)))
            (error
             (push (cons pair (error-message-string err)) errors))))
        (condition-case err
            (autoslip-howm--ensure-master-link parent)
          (error
           (push (cons (cons parent-address "<master-link>")
                       (error-message-string err))
                 errors)))
        ;; Rebuild the Child Notes section in folgezettel order, with
        ;; each child rendered as a level-3 heading carrying its title.
        (condition-case err
            (autoslip-howm--rebuild-child-notes-of
             (autoslip-howm--find-note-by-address parent-address))
          (error
           (push (cons (cons parent-address "<rebuild-child-notes>")
                       (error-message-string err))
                 errors)))))
    (list :created (gethash 'created counters 0)
          :renamed (gethash 'renamed counters 0)
          :renumbered (gethash 'renumbered counters 0)
          :adopted (gethash 'adopted counters 0)
          :unchanged (gethash 'unchanged counters 0)
          :errors (nreverse errors))))

;;;###autoload
(defun autoslip-howm-import-children-from-obsidian (markdown-file
                                                    parent-address)
  "Import child notes from MARKDOWN-FILE under PARENT-ADDRESS.

MARKDOWN-FILE may use either standard markdown links of the form
\"[N.M Title](N.M%20Title.md)\" or Obsidian wikilinks of the form
\"[[N.M Title]]\".  Entries whose address does not lie under
PARENT-ADDRESS are skipped silently, so a section listing the 00.
index or other navigational links is harmless.

For each valid entry the four-tier reconciliation is applied,
which checks address match, title-slug match, file-on-disk, and
create in that order, exactly as for the 00. import.  After
the dispatch a parent backlink is
ensured in each child and a forward link is ensured in the parent;
both insertions are skipped when the link already exists.  The
parent itself gets one upward link to the 00. index of indices,
under the heading named by `autoslip-howm-master-link-heading'.

When called from a buffer that already represents a folgezettel
note, that note's address is offered as the default parent."
  (interactive
   (let* ((current (autoslip-howm--find-note-at-point))
          (default (and current (plist-get current :address))))
     (list (read-file-name "Markdown child list: " nil nil t)
           (read-string
            (format "Parent folgezettel address%s: "
                    (if default (format " (default %s)" default) ""))
            nil nil default))))
  (autoslip-howm--maybe-rescan)
  (let ((errs (autoslip-howm-validate-address-full parent-address)))
    (when errs
      (user-error "Invalid parent address: %s"
                  (string-join errs "; "))))
  (unless (autoslip-howm--find-note-by-address parent-address)
    (user-error "Parent note %s not found in Howm vault" parent-address))
  (let* ((all-entries (autoslip-howm--parse-obsidian-children markdown-file))
         (filtered (seq-filter
                    (lambda (e)
                      (and (string-prefix-p parent-address (car e))
                           (not (string= parent-address (car e)))))
                    all-entries))
         (result (autoslip-howm--apply-children-import
                  filtered parent-address 'obsidian))
         (errs (plist-get result :errors)))
    (when errs
      (with-output-to-temp-buffer "*Autoslip-Howm Children Import Errors*"
        (princ (format "%d entries failed:\n\n" (length errs)))
        (dolist (e errs)
          (princ (format "  %s -> %s\n    %s\n"
                         (car (car e)) (cdr (car e)) (cdr e))))))
    (message
     (concat "Imported %d children under %s: "
             "%d created, %d renamed, %d renumbered, "
             "%d adopted, %d unchanged%s")
     (length filtered)
     parent-address
     (plist-get result :created)
     (plist-get result :renamed)
     (plist-get result :renumbered)
     (plist-get result :adopted)
     (plist-get result :unchanged)
     (if errs (format ", %d ERRORS" (length errs)) ""))))


;;; ============================================================================
;;; Importing a single atomic note from Obsidian
;;; ============================================================================
;;
;; A separate command imports ONE Obsidian markdown note.  The address
;; is derived from the file name (the leading folgezettel before the
;; first space).  The title is taken from YAML front matter when
;; present, then from the H1 line, then from the file name.  The body
;; is everything between the H1 and the first auto-managed section
;; (Parent Note, Child Notes, Related Notes).  Auto-managed sections
;; are dropped because Howm regenerates them from cache.

(defun autoslip-howm--parse-yaml-front-matter (text)
  "Parse YAML front-matter TEXT and return a plist of known keys.
Recognized keys: :title, :tags, :source, :date-created.  Other
keys are ignored.  This is a crude line-based parser; only flat
scalar values and one-level list values (one entry per indented
hyphen line) are supported."
  (with-temp-buffer
    (insert text)
    (let ((result nil)
          (tags nil))
      (dolist (key '("title" "source" "date-created"))
        (goto-char (point-min))
        (when (re-search-forward
               (concat "^" (regexp-quote key) ":[ \t]*\\(.+\\)$")
               nil t)
          (setq result
                (plist-put result
                           (intern (concat ":" key))
                           (string-trim (match-string 1))))))
      (goto-char (point-min))
      (when (re-search-forward "^tags:[ \t]*$" nil t)
        (forward-line 1)
        (while (looking-at "^[ \t]*-[ \t]+\\(.+\\)$")
          (push (string-trim (match-string 1)) tags)
          (forward-line 1))
        (setq result (plist-put result :tags (nreverse tags))))
      result)))

(defun autoslip-howm--parse-obsidian-note-file (file)
  "Parse Obsidian markdown FILE and return its parts as a plist.

Keys in the returned plist:
  :address          Folgezettel parsed from the file name, canonicalized.
  :title            Title from YAML, falling back to H1, then file name.
  :body             Prose between the H1 and the first managed section.
  :tags             List of tag strings from YAML, or nil.
  :source           Raw `source' field from YAML, or nil.
  :date-created     Raw `date-created' field from YAML, or nil.
  :parent-address   Parsed parent folgezettel, or nil."
  (let* ((basename (file-name-base file))
         (filename-addr nil)
         (filename-title nil))
    (when (string-match
           "\\`\\([0-9]+\\(?:\\.[0-9a-z]*\\)?\\)[ \t]+\\(.*\\)\\'"
           basename)
      (setq filename-addr (autoslip-howm--canonicalize-root
                           (match-string 1 basename)))
      (setq filename-title (string-trim (match-string 2 basename))))
    (with-temp-buffer
      (insert-file-contents file)
      (goto-char (point-min))
      (let ((fm nil)
            (h1-title nil)
            (body "")
            (parent-addr nil))
        (when (looking-at "^---[ \t]*\n")
          (forward-line 1)
          (let ((fm-start (point)))
            (when (re-search-forward "^---[ \t]*$" nil t)
              (setq fm (autoslip-howm--parse-yaml-front-matter
                        (buffer-substring-no-properties
                         fm-start (line-beginning-position))))
              (forward-line 1))))
        (while (and (not (eobp)) (looking-at "^[ \t]*$"))
          (forward-line 1))
        (when (looking-at "^#[ \t]+\\(.+?\\)[ \t]*$")
          (setq h1-title (string-trim (match-string 1)))
          (forward-line 1))
        (let ((body-start (point))
              (body-end nil))
          (if (re-search-forward
               "^##[ \t]+\\(Parent Note\\|Child Notes\\|Related Notes\\)\\b"
               nil t)
              (setq body-end (match-beginning 0))
            (setq body-end (point-max)))
          (setq body (string-trim
                      (buffer-substring-no-properties
                       body-start body-end))))
        (cond
         ((and fm (plist-get fm :source))
          (when (string-match
                 "\\[\\[?\\([0-9]+\\(?:\\.[0-9a-z]*\\)?\\)"
                 (plist-get fm :source))
            (setq parent-addr
                  (autoslip-howm--canonicalize-root
                   (match-string 1 (plist-get fm :source))))))
         (filename-addr
          (setq parent-addr
                (autoslip-howm--parse-address filename-addr))))
        (list :address filename-addr
              :title (or (and fm (plist-get fm :title))
                         h1-title
                         filename-title)
              :body body
              :tags (and fm (plist-get fm :tags))
              :source (and fm (plist-get fm :source))
              :date-created (and fm (plist-get fm :date-created))
              :parent-address parent-addr)))))

(defun autoslip-howm--managed-heading-regexp ()
  "Return a regexp that matches any Howm-managed section heading."
  (let ((names (delq nil
                     (list autoslip-howm-backlink-heading
                           autoslip-howm-forward-link-heading
                           autoslip-howm-crosslink-heading
                           autoslip-howm-master-link-heading))))
    (concat "^\\*+ +"
            (regexp-opt names t)
            "\\b")))

(defun autoslip-howm--find-body-region ()
  "Return (START . END) of the body region in the current buffer.
The body starts on the line after the self-anchor and ends at the
first Howm-managed section heading or end of buffer."
  (save-excursion
    (goto-char (point-min))
    (forward-line 1)
    (when (looking-at (concat "^"
                              (regexp-quote autoslip-howm-anchor-marker)
                              "[ \t]+"))
      (forward-line 1))
    (let* ((start (point))
           (end (if (re-search-forward
                     (autoslip-howm--managed-heading-regexp) nil t)
                    (match-beginning 0)
                  (point-max))))
      (cons start end))))

(defun autoslip-howm--replace-body (new-body)
  "Replace the body region of the current buffer with NEW-BODY."
  (let ((region (autoslip-howm--find-body-region)))
    (delete-region (car region) (cdr region))
    (goto-char (car region))
    (unless (bolp) (insert "\n"))
    (insert "\n" (string-trim new-body) "\n\n")))

(defun autoslip-howm--append-body (new-body)
  "Append NEW-BODY at the end of the body region in the current buffer."
  (let ((region (autoslip-howm--find-body-region)))
    (goto-char (cdr region))
    (unless (bolp) (insert "\n"))
    (insert "\n" (string-trim new-body) "\n\n")))

(defun autoslip-howm--body-region-empty-p ()
  "Return non-nil when the body region in the current buffer is empty.
Whitespace and blank lines do not count as content."
  (let* ((region (autoslip-howm--find-body-region))
         (text (buffer-substring-no-properties (car region) (cdr region))))
    (string-match-p "\\`[ \t\n]*\\'" text)))

(defun autoslip-howm--import-single-note-internal (parsed &optional quiet)
  "Internal worker for the single-atomic-note import.
PARSED is the plist returned by
`autoslip-howm--parse-obsidian-note-file'.  Runs reconciliation,
writes the body, and ensures the parent link.  When QUIET is
non-nil, the `prompt' value of
`autoslip-howm-import-note-body-strategy' silently falls back to
`replace' instead of asking once per file.  Returns the
reconciliation outcome symbol."
  (let* ((address (plist-get parsed :address))
         (title (plist-get parsed :title))
         (body (or (plist-get parsed :body) ""))
         (parent-addr (plist-get parsed :parent-address)))
    (unless (and address (not (string-empty-p address)))
      (error "Could not parse a folgezettel address from file name"))
    (unless (and title (not (string-empty-p title)))
      (error "Could not derive a title"))
    (let ((errs (autoslip-howm-validate-address-full address)))
      (when errs
        (error "Invalid address %s: %s"
               address (string-join errs "; "))))
    (let* ((consumed (make-hash-table :test 'equal))
           (outcome (autoslip-howm--reconcile-entry
                     address title 'obsidian consumed)))
      (autoslip-howm-rescan)
      (let* ((note (autoslip-howm--find-note-by-address address))
             (file (and note (plist-get note :file))))
        (unless file
          (error "Reconciliation did not yield a file for %s" address))
        (let* ((default-strategy autoslip-howm-import-note-body-strategy)
               (strategy
                (cond
                 ((eq default-strategy 'prompt)
                  (with-current-buffer (find-file-noselect file)
                    (cond
                     ((or (autoslip-howm--body-region-empty-p)
                          (memq outcome '(created adopted)))
                      'replace)
                     (quiet 'replace)
                     ((y-or-n-p
                       (format
                        "Note %s already has a body.  Replace it? "
                        address))
                      'replace)
                     (t 'skip))))
                 (t default-strategy))))
          (unless (eq strategy 'skip)
            (with-current-buffer (find-file-noselect file)
              (cond
               ((eq strategy 'append)
                (autoslip-howm--append-body body))
               (t
                (autoslip-howm--replace-body body)))
              (save-buffer)))
          (let* ((parent (and parent-addr
                              (autoslip-howm--find-note-by-address
                               parent-addr))))
            (when parent
              (autoslip-howm--ensure-bidirectional-link note parent))))
        outcome))))

;;;###autoload
(defun autoslip-howm-import-note-from-obsidian (markdown-file)
  "Import a single Obsidian atomic note from MARKDOWN-FILE.

The folgezettel address is taken from the leading token of the
file's base name.  The title is taken from YAML `title' when
present, falling back to the first H1 line, then to the file name.
The body is everything between the H1 and the first auto-managed
section (Parent Note, Child Notes, Related Notes).  Tags,
date-created, and the Obsidian-managed sections themselves are
not carried over to Howm.

The same four-tier reconciliation runs, that is address match,
title-slug match, file-on-disk, then create.  The imported body
is then written into the body region of the resulting Howm note
according to `autoslip-howm-import-note-body-strategy'.  When the
parent note referenced by the YAML `source' field (or derived from
the imported address) exists in the Howm vault, a bidirectional
link is also set up between the imported note and its parent."
  (interactive (list (read-file-name "Obsidian note file: " nil nil t)))
  (autoslip-howm--maybe-rescan)
  (let* ((parsed (autoslip-howm--parse-obsidian-note-file markdown-file))
         (outcome (autoslip-howm--import-single-note-internal parsed)))
    (autoslip-howm-rescan)
    (let* ((note (autoslip-howm--find-note-by-address
                  (plist-get parsed :address)))
           (file (and note (plist-get note :file)))
           (parent-addr (plist-get parsed :parent-address)))
      (when file (find-file file))
      (message
       "Imported %s %s (%s%s)"
       (plist-get parsed :address)
       (plist-get parsed :title)
       outcome
       (if (and parent-addr
                (autoslip-howm--find-note-by-address parent-addr))
           (format ", parent %s linked" parent-addr)
         ", parent not linked")))))


;;; ============================================================================
;;; Bulk import from Finder selection or a directory
;;; ============================================================================

(defcustom autoslip-howm-osascript-program "osascript"
  "Name or absolute path of the osascript executable.
Used by `autoslip-howm-import-notes-from-finder-selection' on macOS.
Other platforms do not ship osascript; the Finder-selection command
will refuse to run there."
  :type 'string
  :group 'autoslip-howm)

(defcustom autoslip-howm-finder-selection-applescript
  "tell application \"Finder\"
     set thePaths to \"\"
     repeat with anItem in (get selection)
       set thePaths to thePaths & (POSIX path of (anItem as alias)) & linefeed
     end repeat
     return thePaths
   end tell"
  "AppleScript that returns Finder's current selection as text.
Standard output is parsed as one POSIX path per line.  Empty lines
are ignored."
  :type 'string
  :group 'autoslip-howm)

(defun autoslip-howm--finder-selection ()
  "Return the list of POSIX paths currently selected in macOS Finder.
Calls osascript to evaluate
`autoslip-howm-finder-selection-applescript' and splits the
standard output on newlines.  Signals a user-error when osascript
is not on PATH; signals a regular error when the AppleScript
itself fails."
  (unless (executable-find autoslip-howm-osascript-program)
    (user-error
     "Could not find %s on PATH; this command requires macOS"
     autoslip-howm-osascript-program))
  (with-temp-buffer
    (let ((status (call-process
                   autoslip-howm-osascript-program nil t nil
                   "-e" autoslip-howm-finder-selection-applescript)))
      (cond
       ((zerop status)
        (seq-filter
         (lambda (s) (not (string-empty-p s)))
         (mapcar #'string-trim
                 (split-string (buffer-string) "\n"))))
       (t (error "AppleScript failed (exit %s): %s"
                 status (string-trim (buffer-string))))))))

(defun autoslip-howm--import-note-files (files)
  "Import every path in FILES as an atomic Obsidian note.
After all imports, the Child Notes section of every parent that
received new children is rebuilt in folgezettel order, with each
child rendered as a level-3 heading carrying its title.

Returns a plist with totals :total, :imported, :skipped, and
:errors (a list of (FILE . MESSAGE) pairs).  Errors in any one
file do not abort the rest of the run."
  (autoslip-howm--maybe-rescan)
  (let ((total 0) (imported 0) (skipped 0) (errors '())
        (parents-touched (make-hash-table :test 'equal)))
    (save-window-excursion
      (dolist (file files)
        (setq total (1+ total))
        (condition-case err
            (let ((parsed (autoslip-howm--parse-obsidian-note-file file)))
              (cond
               ((or (null (plist-get parsed :address))
                    (string-empty-p (or (plist-get parsed :address) "")))
                (setq skipped (1+ skipped))
                (push (cons file "no folgezettel in file name")
                      errors))
               (t
                (autoslip-howm--import-single-note-internal parsed t)
                (let ((p (plist-get parsed :parent-address)))
                  (when p (puthash p t parents-touched)))
                (setq imported (1+ imported)))))
          (error
           (push (cons file (error-message-string err)) errors)))))
    (autoslip-howm-rescan)
    (maphash
     (lambda (parent-addr _)
       (condition-case err
           (let ((parent (autoslip-howm--find-note-by-address
                          parent-addr)))
             (when parent
               (autoslip-howm--rebuild-child-notes-of parent)))
         (error
          (push (cons (cons parent-addr "<rebuild-child-notes>")
                      (error-message-string err))
                errors))))
     parents-touched)
    (list :total total
          :imported imported
          :skipped skipped
          :errors (nreverse errors))))

(defun autoslip-howm--run-bulk-import (files source-label)
  "Run the bulk importer on FILES and report results.
SOURCE-LABEL is the human-readable origin shown in the final
message and in the error buffer header."
  (let* ((result (autoslip-howm--import-note-files files))
         (errs (plist-get result :errors)))
    (when errs
      (with-output-to-temp-buffer "*Autoslip-Howm Bulk Import Errors*"
        (princ (format "%d file(s) failed during bulk import from %s:\n\n"
                       (length errs) source-label))
        (dolist (e errs)
          (princ (format "  %s\n    %s\n" (car e) (cdr e))))))
    (message
     "Imported %d/%d files from %s (%d skipped, %d errors)"
     (plist-get result :imported)
     (plist-get result :total)
     source-label
     (plist-get result :skipped)
     (length errs))))

;;;###autoload
(defun autoslip-howm-import-notes-from-finder-selection ()
  "Import every Markdown file currently selected in macOS Finder.

Each selected `.md' file is routed through the single-atomic-note
import path.  Non-Markdown items in the selection are filtered
out.  In this bulk path the `prompt' value of
`autoslip-howm-import-note-body-strategy' silently falls back to
`replace' to avoid asking once per file.

Failures on individual files are collected in
`*Autoslip-Howm Bulk Import Errors*' and do not abort the rest of
the run.

Requires macOS and an osascript executable on PATH."
  (interactive)
  (let* ((paths (autoslip-howm--finder-selection))
         (mds (seq-filter
               (lambda (p) (string-match-p "\\.md\\'" p))
               paths)))
    (cond
     ((null paths)
      (user-error "Finder has no current selection"))
     ((null mds)
      (user-error "Finder selection has no .md files (got %d items)"
                  (length paths)))
     ((not (yes-or-no-p
            (format "Import %d Markdown file(s) from Finder selection? "
                    (length mds))))
      (message "Bulk import cancelled"))
     (t
      (autoslip-howm--run-bulk-import mds "Finder selection")))))

;;;###autoload
(defun autoslip-howm-import-notes-from-directory (dir &optional recursive)
  "Import every .md file under DIR as an atomic Obsidian note.
Non-recursive by default.  With a prefix argument (or when
RECURSIVE is non-nil from Lisp), descend into subdirectories.

Each file is routed through the single-atomic-note import path.
Failures on individual files do not abort the rest of the run."
  (interactive
   (list (read-directory-name "Obsidian notes directory: ")
         current-prefix-arg))
  (let ((files (if recursive
                   (directory-files-recursively dir "\\.md\\'")
                 (directory-files dir t "\\.md\\'" t))))
    (cond
     ((null files)
      (user-error "No .md files found in %s" dir))
     ((not (yes-or-no-p
            (format "Import %d Markdown file(s) from %s? "
                    (length files) dir)))
      (message "Bulk import cancelled"))
     (t
      (autoslip-howm--run-bulk-import
       files (file-name-as-directory dir))))))


;;;###autoload
(defun autoslip-howm-show-chain-of-thought ()
  "Show the ancestor chain for the current note in a buffer.
Phase 5 will add a dedicated major mode and an insert-back action;
this baseline implementation prints a summary."
  (interactive)
  (autoslip-howm--maybe-rescan)
  (let* ((note (autoslip-howm--find-note-at-point))
         (fz (and note (plist-get note :address))))
    (unless fz
      (user-error "Current buffer has no folgezettel-indexed note"))
    (let ((chain (autoslip-howm--ancestor-addresses fz))
          (buf (get-buffer-create "*Autoslip-Howm Chain*")))
      (with-current-buffer buf
        (let ((inhibit-read-only t))
          (erase-buffer)
          (special-mode)
          (insert (format "Chain of Thought for %s\n" fz))
          (insert (make-string 60 ?=) "\n\n")
          (let ((depth 0))
            (dolist (addr chain)
              (let* ((n (autoslip-howm--find-note-by-address addr))
                     (title (and n (plist-get n :title))))
                (insert (make-string (* 2 depth) ?\s))
                (if n
                    (insert-text-button
                     (format "%s %s" addr (or title ""))
                     'follow-link t
                     'action (lambda (_) (find-file (plist-get n :file))))
                  (insert (format "%s (no note)" addr)))
                (insert "\n")
                (setq depth (1+ depth)))))
          (goto-char (point-min))))
      (switch-to-buffer-other-window buf))))

;;;###autoload
(defun autoslip-howm-insert-chain-of-thought ()
  "Insert the ancestor chain at point as a bullet list."
  (interactive)
  (autoslip-howm--maybe-rescan)
  (let* ((note (autoslip-howm--find-note-at-point))
         (fz (and note (plist-get note :address))))
    (unless fz
      (user-error "Current buffer has no folgezettel-indexed note"))
    (let ((chain (autoslip-howm--ancestor-addresses fz))
          (depth 0))
      (unless (bolp) (insert "\n"))
      (dolist (addr chain)
        (let* ((n (autoslip-howm--find-note-by-address addr))
               (title (and n (plist-get n :title)))
               (kw (and n (plist-get n :keyword))))
          (insert (make-string (* 2 depth) ?\s) "- ")
          (cond
           (kw (insert (format "%s %s (%s)\n"
                               autoslip-howm-goto-marker kw
                               (or title addr))))
           (t  (insert (format "%s (no note)\n" addr))))
          (setq depth (1+ depth)))))))

;;;###autoload
(defun autoslip-howm-show-crosslinked-chains ()
  "Stub for Phase 5; report that the feature is not yet implemented."
  (interactive)
  (user-error "autoslip-howm-show-crosslinked-chains is scheduled for Phase 5"))


;;; ============================================================================
;;; Reparenting
;;; ============================================================================

(defun autoslip-howm--rewrite-title-line (old-addr new-addr)
  "Replace OLD-ADDR with NEW-ADDR in the title line of the current buffer."
  (save-excursion
    (goto-char (point-min))
    (when (re-search-forward
           (concat "\\b" (regexp-quote old-addr) "\\b")
           (line-end-position 5) t)
      (replace-match new-addr t t))))

(defun autoslip-howm--rewrite-anchor-line (old-addr new-addr)
  "Rewrite the self-anchor in this buffer, replacing OLD-ADDR with NEW-ADDR."
  (save-excursion
    (goto-char (point-min))
    (let ((pat (concat "^"
                       (regexp-quote autoslip-howm-anchor-marker)
                       "[ \t]+\\("
                       (regexp-quote autoslip-howm-keyword-namespace)
                       "\\):"
                       (regexp-quote old-addr)
                       ":\\([^[:space:]]+\\)")))
      (when (re-search-forward pat nil t)
        (replace-match
         (format "%s \\1:%s:\\2"
                 autoslip-howm-anchor-marker
                 new-addr)
         nil nil)))))

(defun autoslip-howm--rewrite-inbound-keyword (old-uid old-addr new-addr)
  "Across the vault, rewrite keywords with OLD-UID and OLD-ADDR to use NEW-ADDR."
  (let ((count 0))
    (dolist (n (autoslip-howm--all-notes))
      (let ((file (plist-get n :file)))
        (with-current-buffer (find-file-noselect file)
          (save-excursion
            (goto-char (point-min))
            (let ((pat (concat
                        "\\("
                        (regexp-quote autoslip-howm-keyword-namespace)
                        "\\):"
                        (regexp-quote old-addr)
                        ":"
                        (regexp-quote old-uid))))
              (while (re-search-forward pat nil t)
                (replace-match
                 (format "\\1:%s:%s" new-addr old-uid)
                 nil nil)
                (setq count (1+ count)))))
          (when (> count 0) (save-buffer)))))
    count))

(defun autoslip-howm--rename-note-file (old-file old-addr new-addr)
  "Rename OLD-FILE on disk, replacing leading OLD-ADDR with NEW-ADDR."
  (let* ((dir (file-name-directory old-file))
         (base (file-name-nondirectory old-file)))
    (when (string-match (concat "\\`" (regexp-quote old-addr) "\\b") base)
      (let ((new-base (replace-match new-addr t t base)))
        (let ((new-file (expand-file-name new-base dir)))
          (when (file-exists-p new-file)
            (user-error "Cannot rename: target %s already exists" new-file))
          (rename-file old-file new-file)
          new-file)))))

;;;###autoload
(defun autoslip-howm-reparent (new-address)
  "Renumber the current note's folgezettel to NEW-ADDRESS.
Rewrites the title line, the self-anchor's address segment, every
inbound keyword reference across the vault, and the file name.
The UID of the note does not change, so existing inbound goto links
remain valid."
  (interactive (list (read-string "New folgezettel address: ")))
  (autoslip-howm--maybe-rescan)
  (let* ((note (autoslip-howm--find-note-at-point))
         (old-addr (and note (plist-get note :address)))
         (kw (and note (plist-get note :keyword)))
         (uid (and kw (autoslip-howm--keyword-uid kw)))
         (errors (autoslip-howm-validate-address-full new-address)))
    (cond
     ((not note) (user-error "No autoslip-howm note in this buffer"))
     ((not old-addr)
      (user-error "Current buffer has no folgezettel address"))
     (errors (user-error "Invalid new address: %s"
                         (string-join errors "; ")))
     ((string= old-addr new-address)
      (user-error "New address is identical to the current one"))
     ((autoslip-howm--find-note-by-address new-address)
      (user-error "Address '%s' is already in use" new-address))
     (t
      (autoslip-howm--rewrite-title-line old-addr new-address)
      (when uid
        (autoslip-howm--rewrite-anchor-line old-addr new-address))
      (save-buffer)
      (when (and uid autoslip-howm-rename-files-on-reparent)
        (let ((new-file (autoslip-howm--rename-note-file
                         (buffer-file-name) old-addr new-address)))
          (when new-file
            (set-visited-file-name new-file nil t)
            (set-buffer-modified-p nil))))
      (when uid
        (autoslip-howm--rewrite-inbound-keyword uid old-addr new-address))
      (autoslip-howm-rescan)
      (message "Reparented %s -> %s" old-addr new-address)))))

;;;###autoload
(defun autoslip-howm-reparent-subtree (new-address)
  "Renumber the current note and every descendant.
Each descendant's folgezettel has its OLD prefix replaced by NEW-ADDRESS."
  (interactive (list (read-string "New address for subtree root: ")))
  (autoslip-howm--maybe-rescan)
  (let* ((note (autoslip-howm--find-note-at-point))
         (old-addr (and note (plist-get note :address))))
    (unless old-addr
      (user-error "Current buffer has no folgezettel address"))
    (let* ((descendants
            (seq-filter
             (lambda (n)
               (let ((a (plist-get n :address)))
                 (and a
                      (string-prefix-p old-addr a)
                      (not (string= old-addr a)))))
             (autoslip-howm--all-notes))))
      (autoslip-howm-reparent new-address)
      (dolist (d descendants)
        (let* ((d-old (plist-get d :address))
               (d-new (concat new-address
                              (substring d-old (length old-addr))))
               (file (plist-get d :file)))
          (with-current-buffer (find-file-noselect file)
            (autoslip-howm--rewrite-title-line d-old d-new)
            (autoslip-howm--rewrite-anchor-line d-old d-new)
            (save-buffer)
            (when autoslip-howm-rename-files-on-reparent
              (let ((new-file (autoslip-howm--rename-note-file
                               (buffer-file-name) d-old d-new)))
                (when new-file
                  (set-visited-file-name new-file nil t)
                  (set-buffer-modified-p nil)))))
          (let ((kw (plist-get d :keyword)))
            (when kw
              (autoslip-howm--rewrite-inbound-keyword
               (autoslip-howm--keyword-uid kw) d-old d-new)))))
      (autoslip-howm-rescan)
      (message "Reparented subtree %s -> %s (%d descendants)"
               old-addr new-address (length descendants)))))


;;; ============================================================================
;;; Howm hook integration
;;; ============================================================================

(defun autoslip-howm--after-create ()
  "Wire bidirectional links for a note just produced by howm.
If the new note's title carries a folgezettel and the parent exists,
write the bidirectional links."
  (when buffer-file-name
    (let* ((line (autoslip-howm--read-first-nonempty-line buffer-file-name))
           (title (autoslip-howm--strip-title-marker line))
           (fz (autoslip-howm--extract-from-title title)))
      (when fz
        (autoslip-howm--ensure-self-anchor fz)
        (save-buffer)
        (autoslip-howm-rescan)
        (let* ((parent-addr (autoslip-howm--parse-address fz))
               (parent (and parent-addr
                            (autoslip-howm--find-note-by-address
                             parent-addr))))
          (when parent
            (autoslip-howm--insert-backlink (plist-get parent :keyword))
            (save-buffer)
            (autoslip-howm--insert-forward-link
             (autoslip-howm--read-self-keyword buffer-file-name)
             (plist-get parent :file))))))))


;;; ============================================================================
;;; Following links at point
;;; ============================================================================

;;;###autoload
(defun autoslip-howm-follow-link-at-point ()
  "Follow the autoslip wiki link on the current line.
Looks for a goto-link line (\">>> autoslip:ADDR:UID\") or a
self-anchor line (\"<<< autoslip:ADDR:UID\") at point, parses
the keyword, and visits the corresponding note.  Resolution uses
the keyword's UID first and falls back to the address segment,
which keeps the link valid across reparents.

Errors when no autoslip keyword is present on the current line or
when no matching note exists in the cache."
  (interactive)
  (autoslip-howm--maybe-rescan)
  (let* ((line (buffer-substring-no-properties
                (line-beginning-position)
                (line-end-position)))
         (pat (concat (regexp-quote autoslip-howm-keyword-namespace)
                      ":[^[:space:]]+")))
    (cond
     ((not (string-match pat line))
      (user-error "No autoslip keyword on this line"))
     (t
      (let* ((kw (match-string 0 line))
             (uid (autoslip-howm--keyword-uid kw))
             (target (or (and uid (autoslip-howm--find-note-by-uid uid))
                         (autoslip-howm--find-note-by-address
                          (autoslip-howm--keyword-address kw)))))
        (if target
            (find-file (plist-get target :file))
          (user-error "No note in cache matches %s" kw)))))))

(defun autoslip-howm--org-open-at-point-handler ()
  "Hook for `org-open-at-point-functions'.
When the current line carries an autoslip wiki keyword, follow it
and return non-nil so Org's default handler is skipped.  Returns
nil on any other line, leaving Org's behavior intact."
  (let ((line (buffer-substring-no-properties
               (line-beginning-position)
               (line-end-position))))
    (when (string-match
           (concat (regexp-quote autoslip-howm-keyword-namespace)
                   ":[^[:space:]]+")
           line)
      (autoslip-howm-follow-link-at-point)
      t)))


;;; ============================================================================
;;; Minor mode
;;; ============================================================================

;;;###autoload
(define-minor-mode autoslip-howm-mode
  "Global minor mode for automatic folgezettel linking in howm.
When enabled, hooks into howm's note creation to wire up parent and
child references automatically and integrates with Org so
`org-open-at-point' transparently follows autoslip keywords on the
current line."
  :global t
  :group 'autoslip-howm
  :lighter " FZh"
  (cond
   (autoslip-howm-mode
    (add-hook 'howm-create-file-hook #'autoslip-howm--after-create)
    (add-hook 'howm-after-save-hook #'autoslip-howm-rescan)
    (add-hook 'org-open-at-point-functions
              #'autoslip-howm--org-open-at-point-handler))
   (t
    (remove-hook 'howm-create-file-hook #'autoslip-howm--after-create)
    (remove-hook 'howm-after-save-hook #'autoslip-howm-rescan)
    (remove-hook 'org-open-at-point-functions
                 #'autoslip-howm--org-open-at-point-handler))))

(provide 'autoslip-howm)

;;; autoslip-howm.el ends here
