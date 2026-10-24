# roblox-dev-kit maintenance targets. Run `make all` before committing.

SHELL := /bin/bash
.SHELLFLAGS := -euo pipefail -c

# Skills that ship scripts get a vendored copy of lib/common.sh (they are installed one folder at a time).
SCRIPT_SKILLS := $(patsubst skills/%/scripts/,%,$(wildcard skills/*/scripts/))
VENDOR_HEADER := \# vendored from /lib/common.sh — edit the source, run make sync-lib
SERVERS_COPY := skills/roblox-setup/assets/mcp-servers.json

.PHONY: all sync-lib check-sync lint test validate

all: check-sync lint validate test

# Vendored copy = shebang, header line, rest of the source.
define vendored_lib
{ head -n 1 lib/common.sh; echo '$(VENDOR_HEADER)'; tail -n +2 lib/common.sh; }
endef

sync-lib:
	@for s in $(SCRIPT_SKILLS); do \
	  mkdir -p "skills/$$s/scripts/lib"; \
	  $(vendored_lib) > "skills/$$s/scripts/lib/common.sh"; \
	  echo "synced skills/$$s/scripts/lib/common.sh"; \
	done
	@mkdir -p $(dir $(SERVERS_COPY)) && cp mcp/servers.json $(SERVERS_COPY) && echo "synced $(SERVERS_COPY)"

check-sync:
	@status=0; \
	for s in $(SCRIPT_SKILLS); do \
	  if ! diff -q <($(vendored_lib)) "skills/$$s/scripts/lib/common.sh" >/dev/null 2>&1; then \
	    echo "drift: skills/$$s/scripts/lib/common.sh differs from lib/common.sh (run make sync-lib)"; status=1; \
	  fi; \
	done; \
	if ! cmp -s mcp/servers.json $(SERVERS_COPY); then \
	  echo "drift: $(SERVERS_COPY) differs from mcp/servers.json (run make sync-lib)"; status=1; \
	fi; \
	[ $$status -eq 0 ] && echo "check-sync: ok"; exit $$status

lint:
	@files=$$(git ls-files -co --exclude-standard -- '*.sh' '*.bash'); \
	shellcheck -x $$files && echo "shellcheck: ok ($$(echo "$$files" | wc -l | tr -d ' ') files)"
	@for f in $$(git ls-files -co --exclude-standard -- '*.json'); do jq empty "$$f" || exit 1; done; echo "json: ok"
	@py=$$(git ls-files -co --exclude-standard -- '*.py'); \
	if [ -n "$$py" ]; then python3 -m py_compile $$py && echo "py_compile: ok"; fi

validate:
	@bash scripts/validate-skills.sh
	@bash scripts/validate-evals.sh

test:
	@bats tests/
