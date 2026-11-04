PREFIX ?= $(HOME)/.local

.PHONY: install uninstall test lint

install:
	install -d $(PREFIX)/bin
	install -m 0755 git-veil $(PREFIX)/bin/git-veil
	@echo "installed $(PREFIX)/bin/git-veil  (make sure $(PREFIX)/bin is on PATH, then: git veil --help)"

uninstall:
	rm -f $(PREFIX)/bin/git-veil

test:
	bash tests/run.sh

lint:
	shellcheck git-veil tests/run.sh
