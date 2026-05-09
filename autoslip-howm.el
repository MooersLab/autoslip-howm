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
  "Return non-nil if ADDRESS is a root, that is digits with optional trailing period."
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
  "Return an error string if ADDRESS contains more than one period."
  (when (and address (stringp address))
    (let ((period-count (length (seq-filter (lambda (c) (= c ?.)) address))))
      (when (> period-count 1)
        (format
         "Invalid address '%s': Only one period is allowed.  Found %d."
         address period-count)))))

(defun autoslip-howm--validate-no-invalid-characters (address)
  "Return an error string if ADDRESS contains invalid characters."
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
  "Return non-nil if address A sorts before B in hierarchical order."
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
  "Time of the last cache build, as a float-time value.")

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
  "Write a parent goto-link in the current buffer using `headings' mode."
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
  "Write a parent reference in the current buffer using `headers' mode."
  (autoslip-howm--set-header-property
   autoslip-howm-parent-property parent-keyword))

(defun autoslip-howm--insert-backlink (parent-keyword)
  "Dispatch on `autoslip-howm-link-storage' for PARENT-KEYWORD."
  (pcase autoslip-howm-link-storage
    ('headers (autoslip-howm--insert-backlink-headers parent-keyword))
    (_        (autoslip-howm--insert-backlink-headings parent-keyword))))

(defun autoslip-howm--insert-forward-link-headings (child-keyword parent-file)
  "Append a Child Notes entry for CHILD-KEYWORD into PARENT-FILE."
  (with-current-buffer (find-file-noselect parent-file)
    (autoslip-howm--insert-under-heading
     autoslip-howm-forward-link-heading
     (autoslip-howm--goto-line child-keyword))
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
org-mode versus plain-text heading style."
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

(defun autoslip-howm-create-note (address title)
  "Create a new howm note with ADDRESS and TITLE.
Writes a self-anchor line, sets up the parent backlink if a parent
exists, writes a forward link in the parent, and returns the new
keyword.

This is the workhorse used by `autoslip-howm-insert-next-child'."
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
  "Rewrite the leading folgezettel of the title line in this buffer."
  (save-excursion
    (goto-char (point-min))
    (when (re-search-forward
           (concat "\\b" (regexp-quote old-addr) "\\b")
           (line-end-position 5) t)
      (replace-match new-addr t t))))

(defun autoslip-howm--rewrite-anchor-line (old-addr new-addr)
  "Rewrite the address segment of the self-anchor in this buffer."
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
  "Rewrite every inbound keyword whose UID is OLD-UID across the vault."
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
  "Rename OLD-FILE so its leading address segment becomes NEW-ADDR."
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
  "Hook function called after howm creates a new file.
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
;;; Minor mode
;;; ============================================================================

;;;###autoload
(define-minor-mode autoslip-howm-mode
  "Global minor mode for automatic folgezettel linking in howm.
When enabled, hooks into howm's note creation to wire up parent and
child references automatically."
  :global t
  :group 'autoslip-howm
  :lighter " FZh"
  (cond
   (autoslip-howm-mode
    (add-hook 'howm-create-file-hook #'autoslip-howm--after-create)
    (add-hook 'howm-after-save-hook #'autoslip-howm-rescan))
   (t
    (remove-hook 'howm-create-file-hook #'autoslip-howm--after-create)
    (remove-hook 'howm-after-save-hook #'autoslip-howm-rescan))))

(provide 'autoslip-howm)

;;; autoslip-howm.el ends here
