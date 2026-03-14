.PHONY: toc_check toc_update watch dev build test test-only test-cov test-file test-pattern test-ci lua_deps wbt_setup i18n_check i18n_fmt hardcode_string_check

ROCKSBIN := $(HOME)/.luarocks/bin
WBT_REF ?= v1-beta
WBT_DIR := ../wow-build-tools

dev: toc_check
	@wow-build-tools build -d -t "Endeavoring" -r ./.release --skipChangelog

toc_check:
	@wow-build-tools toc check \
		-a "Endeavoring" \
		-x embeds.xml \
		--no-splash \
		-b -p

toc_update:
	@wow-build-tools toc update \
		-a "Endeavoring" \
		--no-splash \
		-b -p

watch: toc_check
	@wow-build-tools build watch -t "Endeavoring" -r ./.release

build: toc_check
	@wow-build-tools build -d -t "Endeavoring" -r ./.release

test:
	@$(ROCKSBIN)/busted Endeavoring_spec

test-only:
	@$(ROCKSBIN)/busted --tags=only Endeavoring_spec

# Run tests with coverage
test-cov:
	@rm -rf luacov-html && rm -rf luacov.*out && mkdir -p luacov-html && $(ROCKSBIN)/busted --coverage Endeavoring_spec && $(ROCKSBIN)/luacov && echo "\nCoverage report generated at luacov-html/index.html"

# Run tests for a specific file
# Usage: make test-file FILE=Endeavoring_spec/Sync/Protocol_spec.lua
test-file:
	@if [ -z "$(FILE)" ]; then \
		echo "Usage: make test-file FILE=path/to/test_file.lua"; \
		exit 1; \
	fi
	@$(ROCKSBIN)/busted --verbose "$(FILE)"

# Run tests matching a specific pattern
# Usage: make test-pattern PATTERN="NormalizeKeys"
test-pattern:
	@if [ -z "$(PATTERN)" ]; then \
		echo "Usage: make test-pattern PATTERN=\"test description\""; \
		exit 1; \
	fi
	@$(ROCKSBIN)/busted --verbose --filter="$(PATTERN)" Endeavoring_spec

test-ci:
	@rm -rf luacov-html && rm -rf luacov.*out && mkdir -p luacov-html && $(ROCKSBIN)/busted --coverage -o=TAP Endeavoring_spec && $(ROCKSBIN)/luacov

lua_deps:
	@luarocks install endeavoring-1-1.rockspec --local --force --lua-version 5.4
	@luarocks install busted --local --force --lua-version 5.4

wbt_setup:
	@if [ ! -d "$(WBT_DIR)/scripts/i18n" ]; then \
		echo "Cloning wow-build-tools at ref $(WBT_REF)..."; \
		git clone --depth 1 -b "$(WBT_REF)" \
			https://github.com/McTalian-WoW-Addons/wow-build-tools "$(WBT_DIR)"; \
	else \
		echo "wow-build-tools already available at $(WBT_DIR)"; \
	fi

i18n_check: wbt_setup
	@uv run --project $(WBT_DIR)/scripts/i18n \
		$(WBT_DIR)/scripts/i18n/check_for_missing_locale_keys.py \
		--addon-dir Endeavoring \
		--locale-dir Endeavoring/locale

hardcode_string_check: wbt_setup
	@uv run --project $(WBT_DIR)/scripts/i18n \
		$(WBT_DIR)/scripts/i18n/hardcode_string_check.py \
		--addon-dir Endeavoring

i18n_fmt: wbt_setup
	@uv run --project $(WBT_DIR)/scripts/i18n \
		$(WBT_DIR)/scripts/i18n/organize_translations.py \
		--locale-dir Endeavoring/locale
