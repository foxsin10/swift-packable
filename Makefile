# Build and install swift-packable.
#   make install                     # into ~/.local/bin
#   make install PREFIX=/usr/local   # into /usr/local/bin (may need sudo)
#   make uninstall                   # same PREFIX as install

PREFIX ?= $(HOME)/.local
BINDIR ?= $(PREFIX)/bin
PRODUCT := swift-packable

.PHONY: build install uninstall test clean

build:
	swift build -c release --product $(PRODUCT)

install: build
	install -d "$(BINDIR)"
	install -m 755 "$$(swift build -c release --show-bin-path)/$(PRODUCT)" "$(BINDIR)/$(PRODUCT)"
	@echo "Installed $(BINDIR)/$(PRODUCT) ($$("$(BINDIR)/$(PRODUCT)" --version))"
	@case ":$$PATH:" in *":$(BINDIR):"*) ;; \
	  *) echo "note: $(BINDIR) isn't on PATH; add it (fish: fish_add_path $(BINDIR))";; esac

uninstall:
	rm -f "$(BINDIR)/$(PRODUCT)"

test:
	swift test

clean:
	swift package clean
