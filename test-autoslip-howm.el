;;; test-autoslip-howm.el --- Tests for autoslip-howm -*- lexical-binding: t; -*-

;; Author: Blaine Mooers <blaine-mooers@ou.edu>
;; Keywords: tests

;;; Commentary:
;;
;; ERT test suite for autoslip-howm.  These tests exercise every pure
;; helper (parsing, validation, suggestion, ordering, ancestor walk),
;; the wiki-keyword construction, the file enumeration code, and the
;; round-trip of note creation, link writing, and reparenting against
;; a temporary howm directory.  None of the tests require howm itself
;; to be installed.

;;; Code:

(require 'ert)
(require 'cl-lib)

(let ((here (file-name-directory (or load-file-name buffer-file-name))))
  (add-to-list 'load-path here))
(require 'autoslip-howm)


;;; ============================================================================
;;; Helpers for fixture-based tests
;;; ============================================================================

(defmacro autoslip-howm-test-with-tempdir (var &rest body)
  "Bind VAR to a temporary howm directory and let-bind that as `autoslip-howm-directory'.
Tear down on exit."
  (declare (indent 1) (debug t))
  `(let* ((,var (make-temp-file "autoslip-howm-test-" t))
          (autoslip-howm-directory ,var)
          (autoslip-howm-rescan-on-query t)
          (autoslip-howm--cache nil))
     (unwind-protect
         (progn ,@body)
       (when (file-directory-p ,var)
         (delete-directory ,var t)))))

(defun autoslip-howm-test--touch-org-note (dir address title)
  "Write a minimal org note inside DIR with ADDRESS and TITLE.
Returns the file path."
  (let* ((file (expand-file-name
                (format "%s-%s.org"
                        address
                        (downcase
                         (replace-regexp-in-string
                          "[^a-zA-Z0-9]+" "-" title)))
                dir))
         (uid "testuid1")
         (kw (format "autoslip:%s:%s" address uid)))
    (with-temp-file file
      (insert (format "%s %s\n" address title))
      (insert (format "<<< %s\n" kw)))
    file))


;;; ============================================================================
;;; Pure parsing
;;; ============================================================================

(ert-deftest test-parse-address-numeric ()
  (should (equal (autoslip-howm--parse-address "1.13") "1."))
  (should (equal (autoslip-howm--parse-address "1.2") "1."))
  (should (equal (autoslip-howm--parse-address "5.7") "5.")))

(ert-deftest test-parse-address-letters ()
  (should (equal (autoslip-howm--parse-address "1.2a") "1.2"))
  (should (equal (autoslip-howm--parse-address "1.13aa") "1.13"))
  (should (equal (autoslip-howm--parse-address "1.13z") "1.13")))

(ert-deftest test-parse-address-numbers-after-letters ()
  (should (equal (autoslip-howm--parse-address "1.2a3") "1.2a"))
  (should (equal (autoslip-howm--parse-address "1.2a15") "1.2a"))
  (should (equal (autoslip-howm--parse-address "1.2a3b5") "1.2a3b")))

(ert-deftest test-parse-address-roots ()
  (should (null (autoslip-howm--parse-address "1.")))
  (should (null (autoslip-howm--parse-address "1")))
  (should (null (autoslip-howm--parse-address "13."))))

(ert-deftest test-canonicalize-root ()
  (should (equal (autoslip-howm--canonicalize-root "1") "1."))
  (should (equal (autoslip-howm--canonicalize-root "1.") "1."))
  (should (equal (autoslip-howm--canonicalize-root "1.2") "1.2"))
  (should (equal (autoslip-howm--canonicalize-root "13") "13.")))

(ert-deftest test-root-address-p ()
  (should (autoslip-howm--root-address-p "1"))
  (should (autoslip-howm--root-address-p "1."))
  (should (autoslip-howm--root-address-p "27."))
  (should-not (autoslip-howm--root-address-p "1.2"))
  (should-not (autoslip-howm--root-address-p "1a"))
  (should-not (autoslip-howm--root-address-p "")))


;;; ============================================================================
;;; Title extraction
;;; ============================================================================

(ert-deftest test-extract-from-title ()
  (should (equal (autoslip-howm--extract-from-title "1.2a Crystallography") "1.2a"))
  (should (equal (autoslip-howm--extract-from-title "1. Crystallography") "1."))
  (should (equal (autoslip-howm--extract-from-title "1 Crystallography") "1."))
  (should (null (autoslip-howm--extract-from-title "Crystallography")))
  (should (null (autoslip-howm--extract-from-title nil))))

(ert-deftest test-strip-title-marker ()
  (should (equal (autoslip-howm--strip-title-marker "#+TITLE: 1.2 Topic")
                 "1.2 Topic"))
  (should (equal (autoslip-howm--strip-title-marker "= 1.2 Topic")
                 "1.2 Topic"))
  (should (equal (autoslip-howm--strip-title-marker ", M 1.2 Topic")
                 "1.2 Topic"))
  (should (equal (autoslip-howm--strip-title-marker "1.2 Topic")
                 "1.2 Topic")))


;;; ============================================================================
;;; Letter sequences
;;; ============================================================================

(ert-deftest test-next-letter-sequence ()
  (should (equal (autoslip-howm--next-letter-sequence "a") "b"))
  (should (equal (autoslip-howm--next-letter-sequence "y") "z"))
  (should (equal (autoslip-howm--next-letter-sequence "z") "aa"))
  (should (equal (autoslip-howm--next-letter-sequence "az") "ba"))
  (should (equal (autoslip-howm--next-letter-sequence "zz") "aaa")))


;;; ============================================================================
;;; Validation
;;; ============================================================================

(ert-deftest test-validate-good-addresses ()
  (should (autoslip-howm-validate-address "1."))
  (should (autoslip-howm-validate-address "1.2"))
  (should (autoslip-howm-validate-address "1.2a"))
  (should (autoslip-howm-validate-address "1.13aa"))
  (should (autoslip-howm-validate-address "1.2a15"))
  (should (autoslip-howm-validate-address "1.2a3b5c7d")))

(ert-deftest test-validate-rejects-multiple-periods ()
  (should-not (autoslip-howm-validate-address "1.2.3"))
  (should-not (autoslip-howm-validate-address "1..2"))
  (should (autoslip-howm--validate-no-multiple-periods "1.2.3")))

(ert-deftest test-validate-rejects-invalid-characters ()
  (should-not (autoslip-howm-validate-address "1.2A"))
  (should-not (autoslip-howm-validate-address "1.2/3"))
  (should-not (autoslip-howm-validate-address "1.2!"))
  (should (autoslip-howm--validate-no-invalid-characters "1.2A")))

(ert-deftest test-validate-alternation ()
  ;; A multi-letter sequence ("ab" parsed as one letter segment) is valid.
  (should-not (autoslip-howm--validate-alternation-pattern "1.2ab")))

(ert-deftest test-validate-child-for-parent ()
  ;; Parent ends in number, child must start with letter or .number.
  (should (autoslip-howm--validate-child-for-parent "1.2" "3"))
  (should-not (autoslip-howm--validate-child-for-parent "1.2" "a"))
  (should-not (autoslip-howm--validate-child-for-parent "1.2" ".3"))
  ;; Parent ends in letter, child must start with number.
  (should (autoslip-howm--validate-child-for-parent "1.2a" "b"))
  (should-not (autoslip-howm--validate-child-for-parent "1.2a" "1")))

(ert-deftest test-validate-new-child ()
  (should (null (autoslip-howm-validate-new-child "1." "1.2")))
  (should (null (autoslip-howm-validate-new-child "1.2" "1.2a")))
  (should (autoslip-howm-validate-new-child "1.2" "1.3"))
  (should (autoslip-howm-validate-new-child "1.2" "1.2")))


;;; ============================================================================
;;; Address ordering
;;; ============================================================================

(ert-deftest test-address-depth ()
  (should (= (autoslip-howm--address-depth "1.") 0))
  (should (= (autoslip-howm--address-depth "1") 0))
  (should (= (autoslip-howm--address-depth "1.2") 1))
  (should (= (autoslip-howm--address-depth "1.2a") 2))
  (should (= (autoslip-howm--address-depth "1.2a3") 3))
  (should (= (autoslip-howm--address-depth "1.2a3b") 4)))

(ert-deftest test-address-tokens ()
  (should (equal (autoslip-howm--address-tokens "1.") '(1)))
  (should (equal (autoslip-howm--address-tokens "1.13") '(1 13)))
  (should (equal (autoslip-howm--address-tokens "1.2a") '(1 2 "a")))
  (should (equal (autoslip-howm--address-tokens "1.2a3b")
                 '(1 2 "a" 3 "b"))))

(ert-deftest test-compare-addresses ()
  (should (autoslip-howm--compare-addresses "1." "1.2"))
  (should (autoslip-howm--compare-addresses "1.2" "1.13"))
  (should (autoslip-howm--compare-addresses "1.2a" "1.2b"))
  (should-not (autoslip-howm--compare-addresses "1.13" "1.2"))
  (should-not (autoslip-howm--compare-addresses "1.2b" "1.2a")))


;;; ============================================================================
;;; Ancestor walk
;;; ============================================================================

(ert-deftest test-ancestor-addresses ()
  (should (equal (autoslip-howm--ancestor-addresses "1.2a3")
                 '("1." "1.2" "1.2a" "1.2a3")))
  (should (equal (autoslip-howm--ancestor-addresses "1.")
                 '("1.")))
  (should (null (autoslip-howm--ancestor-addresses nil)))
  (should (null (autoslip-howm--ancestor-addresses ""))))


;;; ============================================================================
;;; Wiki keyword construction
;;; ============================================================================

(ert-deftest test-mint-uid-format ()
  (let ((uid (autoslip-howm--mint-uid)))
    (should (stringp uid))
    (should (= (length uid) 8))
    (should (string-match-p "\\`[a-z0-9]+\\'" uid))))

(ert-deftest test-make-and-parse-keyword ()
  (let* ((kw (autoslip-howm--make-keyword "1.2a" "abcd1234"))
         (parsed (autoslip-howm--parse-keyword kw)))
    (should (equal kw "autoslip:1.2a:abcd1234"))
    (should (equal parsed (list "autoslip" "1.2a" "abcd1234")))
    (should (equal (autoslip-howm--keyword-address kw) "1.2a"))
    (should (equal (autoslip-howm--keyword-uid kw) "abcd1234"))))

(ert-deftest test-parse-keyword-rejects-malformed ()
  (should (null (autoslip-howm--parse-keyword "not-a-keyword")))
  (should (null (autoslip-howm--parse-keyword nil))))


;;; ============================================================================
;;; Filename construction
;;; ============================================================================

(ert-deftest test-slugify ()
  (should (equal (autoslip-howm--slugify "Crystal Symmetry") "crystal-symmetry"))
  (should (equal (autoslip-howm--slugify "  hello WORLD  ") "hello-world"))
  (should (equal (autoslip-howm--slugify "") "note")))

(ert-deftest test-filename-for-address-first ()
  (autoslip-howm-test-with-tempdir dir
    (let ((file (autoslip-howm--filename-for "1.2a" "Crystal Symmetry")))
      (should (string-prefix-p
               (file-name-as-directory dir)
               (expand-file-name file)))
      (should (string-match-p "1\\.2a-crystal-symmetry\\.org\\'" file)))))


;;; ============================================================================
;;; Cache and lookup
;;; ============================================================================

(ert-deftest test-cache-discovers-notes ()
  (autoslip-howm-test-with-tempdir dir
    (autoslip-howm-test--touch-org-note dir "1." "Root")
    (autoslip-howm-test--touch-org-note dir "1.2" "Child A")
    (autoslip-howm-test--touch-org-note dir "1.2a" "Grandchild")
    (autoslip-howm-rescan)
    (let ((notes (autoslip-howm--all-notes)))
      (should (= (length notes) 3))
      (should (autoslip-howm--find-note-by-address "1."))
      (should (autoslip-howm--find-note-by-address "1.2"))
      (should (autoslip-howm--find-note-by-address "1.2a"))
      (should (null (autoslip-howm--find-note-by-address "9.9"))))))

(ert-deftest test-children-notes-of ()
  (autoslip-howm-test-with-tempdir dir
    (autoslip-howm-test--touch-org-note dir "1." "Root")
    (autoslip-howm-test--touch-org-note dir "1.2" "C2")
    (autoslip-howm-test--touch-org-note dir "1.3" "C3")
    (autoslip-howm-test--touch-org-note dir "1.2a" "GC")
    (autoslip-howm-rescan)
    (let ((kids (autoslip-howm--children-notes-of "1.")))
      (should (= (length kids) 2))
      (should (cl-every
               (lambda (n) (member (plist-get n :address) '("1.2" "1.3")))
               kids)))))


;;; ============================================================================
;;; Suggestions
;;; ============================================================================

(ert-deftest test-suggest-from-empty-vault ()
  (autoslip-howm-test-with-tempdir _dir
    (autoslip-howm-rescan)
    (should (equal (autoslip-howm-suggest-next-child "1.") '("1.1")))
    (should (equal (autoslip-howm-suggest-next-child "1.2") '("1.2a")))
    (should (equal (autoslip-howm-suggest-next-child "1.2a") '("1.2a1")))))

(ert-deftest test-suggest-after-children ()
  (autoslip-howm-test-with-tempdir dir
    (autoslip-howm-test--touch-org-note dir "1." "Root")
    (autoslip-howm-test--touch-org-note dir "1.1" "first")
    (autoslip-howm-test--touch-org-note dir "1.2" "second")
    (autoslip-howm-rescan)
    (should (equal (autoslip-howm-suggest-next-child "1.") '("1.3")))))

(ert-deftest test-suggest-after-letter-children ()
  (autoslip-howm-test-with-tempdir dir
    (autoslip-howm-test--touch-org-note dir "1." "Root")
    (autoslip-howm-test--touch-org-note dir "1.2" "p")
    (autoslip-howm-test--touch-org-note dir "1.2a" "a")
    (autoslip-howm-test--touch-org-note dir "1.2b" "b")
    (autoslip-howm-rescan)
    (should (equal (autoslip-howm-suggest-next-child "1.2") '("1.2c")))))


;;; ============================================================================
;;; Diagnostics
;;; ============================================================================

(ert-deftest test-check-duplicate-index ()
  (autoslip-howm-test-with-tempdir dir
    (autoslip-howm-test--touch-org-note dir "1." "Root")
    (autoslip-howm-rescan)
    (should-not (autoslip-howm-check-duplicate-index "1."))
    (should (autoslip-howm-check-duplicate-index "9.9"))))


;;; ============================================================================
;;; Note creation and link writing
;;; ============================================================================

(ert-deftest test-create-note-writes-self-anchor ()
  (autoslip-howm-test-with-tempdir dir
    (let* ((file (autoslip-howm--filename-for "1." "Root")))
      (autoslip-howm-create-note "1." "Root")
      (let ((kw (autoslip-howm--read-self-keyword file)))
        (should kw)
        (should (equal (autoslip-howm--keyword-address kw) "1."))))))

(ert-deftest test-create-child-writes-bidirectional-links ()
  (autoslip-howm-test-with-tempdir dir
    (autoslip-howm-create-note "1." "Root")
    (autoslip-howm-rescan)
    (autoslip-howm-create-note "1.2" "Child")
    (autoslip-howm-rescan)
    (let* ((root (autoslip-howm--find-note-by-address "1."))
           (child (autoslip-howm--find-note-by-address "1.2")))
      (should root)
      (should child)
      ;; The child's body should reference the root's keyword via a goto.
      (let ((root-kw (plist-get root :keyword))
            (child-text (with-temp-buffer
                          (insert-file-contents (plist-get child :file))
                          (buffer-string))))
        (should (string-match-p (regexp-quote root-kw) child-text)))
      ;; The root's body should reference the child's keyword.
      (let ((child-kw (plist-get child :keyword))
            (root-text (with-temp-buffer
                         (insert-file-contents (plist-get root :file))
                         (buffer-string))))
        (should (string-match-p (regexp-quote child-kw) root-text))))))


;;; ============================================================================
;;; Reparenting
;;; ============================================================================

(ert-deftest test-reparent-rewrites-anchor-and-renames-file ()
  (autoslip-howm-test-with-tempdir dir
    (autoslip-howm-create-note "1." "Root")
    (autoslip-howm-rescan)
    (autoslip-howm-create-note "1.2" "Topic")
    (autoslip-howm-rescan)
    (let* ((note (autoslip-howm--find-note-by-address "1.2"))
           (file (plist-get note :file))
           (uid (autoslip-howm--keyword-uid (plist-get note :keyword))))
      (with-current-buffer (find-file-noselect file)
        (autoslip-howm-reparent "1.3"))
      ;; The old file should no longer exist; a 1.3-prefixed file should.
      (should-not (file-exists-p file))
      (autoslip-howm-rescan)
      (let* ((moved (autoslip-howm--find-note-by-address "1.3"))
             (moved-file (plist-get moved :file)))
        (should moved)
        (should (string-match-p "1\\.3-" moved-file))
        ;; UID is preserved across the rewrite.
        (should (equal uid
                       (autoslip-howm--keyword-uid
                        (plist-get moved :keyword))))))))

(provide 'test-autoslip-howm)

;;; test-autoslip-howm.el ends here
