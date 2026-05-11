# Makefile for autoslip-howm
# Build, test, and install the package and documentation.

# ==============================================================================
# Configuration
# ==============================================================================

EMACS ?= emacs

PACKAGE   = autoslip-howm.el
TEST_FILE = test-autoslip-howm.el

TEXI_FILE = autoslip-howm.texi
INFO_FILE = autoslip-howm.info

PREFIX  ?= /usr/local
INFODIR ?= $(PREFIX)/share/info
LISPDIR ?= $(PREFIX)/share/emacs/site-lisp/autoslip-howm

USER_EMACS_DIR ?= $(HOME)/.emacs.d
USER_INFODIR   ?= $(USER_EMACS_DIR)/info
USER_LISPDIR   ?= $(USER_EMACS_DIR)/site-lisp/autoslip-howm

LOAD_PATH  = -L .
BATCH_FLAGS = --batch --no-init-file $(LOAD_PATH)

# ==============================================================================
# Phony targets
# ==============================================================================

.PHONY: all test test-batch test-verbose test-specific compile compile-tests \
        compile-all checkdoc lint check info install install-info install-lisp \
        install-user install-info-user install-lisp-user uninstall uninstall-user \
        clean distclean help list-tests count-tests

all: compile info

# ==============================================================================
# Testing
# ==============================================================================

test: test-batch

test-batch:
	@echo "Running all tests..."
	$(EMACS) $(BATCH_FLAGS) \
		-l ert \
		-l $(PACKAGE) \
		-l $(TEST_FILE) \
		-f ert-run-tests-batch-and-exit

test-verbose:
	@echo "Running tests with verbose output..."
	$(EMACS) $(BATCH_FLAGS) \
		-l ert \
		-l $(PACKAGE) \
		-l $(TEST_FILE) \
		--eval '(setq ert-batch-print-level 10)' \
		--eval '(setq ert-batch-print-length 100)' \
		-f ert-run-tests-batch-and-exit

test-specific:
	@echo "Running test: $(TEST)..."
	$(EMACS) $(BATCH_FLAGS) \
		-l ert \
		-l $(PACKAGE) \
		-l $(TEST_FILE) \
		--eval "(ert-run-tests-batch-and-exit '$(TEST))"

# ==============================================================================
# Compilation
# ==============================================================================

compile: $(PACKAGE:.el=.elc)

$(PACKAGE:.el=.elc): $(PACKAGE)
	@echo "Byte-compiling $(PACKAGE)..."
	$(EMACS) $(BATCH_FLAGS) \
		-f batch-byte-compile $(PACKAGE)

compile-tests: $(TEST_FILE:.el=.elc)

$(TEST_FILE:.el=.elc): $(TEST_FILE) $(PACKAGE)
	@echo "Byte-compiling $(TEST_FILE)..."
	$(EMACS) $(BATCH_FLAGS) \
		-l $(PACKAGE) \
		-f batch-byte-compile $(TEST_FILE)

compile-all: compile compile-tests

# ==============================================================================
# Linting
# ==============================================================================

checkdoc:
	@echo "Running checkdoc..."
	$(EMACS) $(BATCH_FLAGS) \
		-l $(PACKAGE) \
		--eval '(checkdoc-file "$(PACKAGE)")'

lint: checkdoc

check: lint compile-all test

# ==============================================================================
# Documentation
# ==============================================================================

info: $(INFO_FILE)

$(INFO_FILE): $(TEXI_FILE)
	@echo "Building Info documentation..."
	@if command -v makeinfo >/dev/null 2>&1; then \
		makeinfo --no-split $(TEXI_FILE) -o $(INFO_FILE); \
		echo "Generated $(INFO_FILE)"; \
	else \
		echo "ERROR: makeinfo not found.  Install texinfo."; \
		exit 1; \
	fi

# ==============================================================================
# Installation, system-wide
# ==============================================================================

install: install-lisp install-info

install-lisp: compile
	install -d $(LISPDIR)
	install -m 644 $(PACKAGE) $(LISPDIR)/
	install -m 644 $(PACKAGE:.el=.elc) $(LISPDIR)/ 2>/dev/null || true

install-info: info
	install -d $(INFODIR)
	install -m 644 $(INFO_FILE) $(INFODIR)/
	@if command -v install-info >/dev/null 2>&1; then \
		install-info --info-dir=$(INFODIR) $(INFODIR)/$(INFO_FILE) 2>/dev/null || true; \
	fi

uninstall:
	rm -f $(LISPDIR)/$(PACKAGE)
	rm -f $(LISPDIR)/$(PACKAGE:.el=.elc)
	rmdir $(LISPDIR) 2>/dev/null || true
	@if command -v install-info >/dev/null 2>&1; then \
		install-info --delete --info-dir=$(INFODIR) $(INFODIR)/$(INFO_FILE) 2>/dev/null || true; \
	fi
	rm -f $(INFODIR)/$(INFO_FILE)

# ==============================================================================
# Installation, user-local
# ==============================================================================

install-user: install-lisp-user install-info-user

install-lisp-user: compile
	mkdir -p $(USER_LISPDIR)
	cp $(PACKAGE) $(USER_LISPDIR)/
	cp $(PACKAGE:.el=.elc) $(USER_LISPDIR)/ 2>/dev/null || true
	@echo "Add to your init.el:"
	@echo '  (add-to-list '\''load-path "$(USER_LISPDIR)")'

install-info-user: info
	mkdir -p $(USER_INFODIR)
	cp $(INFO_FILE) $(USER_INFODIR)/
	@echo "Add to your init.el:"
	@echo '  (add-to-list '\''Info-additional-directory-list "$(USER_INFODIR)")'

uninstall-user:
	rm -f $(USER_LISPDIR)/$(PACKAGE)
	rm -f $(USER_LISPDIR)/$(PACKAGE:.el=.elc)
	rmdir $(USER_LISPDIR) 2>/dev/null || true
	rm -f $(USER_INFODIR)/$(INFO_FILE)

# ==============================================================================
# Cleaning
# ==============================================================================

clean:
	rm -f *.elc *~ \#*\#
	rm -rf /tmp/autoslip-howm-test-*

distclean: clean
	rm -f $(INFO_FILE)

# ==============================================================================
# Utilities
# ==============================================================================

list-tests:
	@grep -o '^(ert-deftest [a-z0-9_-]*' $(TEST_FILE) | sed 's/(ert-deftest /  /'

count-tests:
	@echo -n "Total tests: "
	@grep -c '^(ert-deftest' $(TEST_FILE)

help:
	@echo "autoslip-howm Makefile"
	@echo "Targets:"
	@echo "  all              Build package and documentation"
	@echo "  test             Run all ERT tests"
	@echo "  compile          Byte-compile the package"
	@echo "  info             Build Info manual"
	@echo "  check            Lint, byte-compile, and test"
	@echo "  install-user     Install to ~/.emacs.d (no sudo)"
	@echo "  clean            Remove compiled files"
