# Local gates for medo. CI runs the same targets, so "green here" means "green there".
LUAUV ?= 0.746
TOOLS  := .tools
LUAU   := $(TOOLS)/luau
LUAU_COMPILE := $(TOOLS)/luau-compile
LUAU_URL := https://github.com/luau-lang/luau/releases/download/$(LUAUV)/luau-ubuntu.zip

.PHONY: check manifest luau test lint tools clean

# The only gate CI enforces.
check: manifest luau test

manifest:
	python3 tools/check_manifest.py

luau: tools
	@set -e; for f in medo/*.luau; do \
		printf 'compile %s\n' "$$f"; \
		$(LUAU_COMPILE) --binary "$$f" > /dev/null; \
	done

test: tools
	@if [ -f tests/logic_test.luau ]; then \
		TZ=UTC $(LUAU) tests/logic_test.luau; \
	else \
		echo "no tests yet"; \
	fi

# Needs a running Noctalia shell; local only, never in CI.
lint:
	noctalia plugins lint medo

tools: $(LUAU)

$(LUAU):
	@mkdir -p $(TOOLS)
	curl -fsSL -o $(TOOLS)/luau.zip "$(LUAU_URL)"
	unzip -o -q $(TOOLS)/luau.zip -d $(TOOLS)
	chmod +x $(LUAU) $(LUAU_COMPILE) $(TOOLS)/luau-analyze
	@echo "luau $(LUAUV) ready in $(TOOLS)/"

clean:
	rm -rf $(TOOLS)
