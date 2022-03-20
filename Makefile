all: static build

DUNE = dune
DUNE_ARGS = --root . --profile=release --default-target @install
INDEX_ODOC_PATH = docs/odoc.html

build-deps:
	opam install . --deps-only --locked

.PHONY: build
build:
	@${DUNE} build ${DUNE_ARGS}

.PHONY: static
static:
	@${MAKE} -C static

.PHONY: doc
doc:
	@${DUNE} build ${DUNE_ARGS} @doc
	ln -sf $(PWD)/_build/default/_doc/_html/index.html ${INDEX_ODOC_PATH}

.PHONY: install
install: static doc
	@${DUNE} install ${DUNE_ARGS}

uninstall:
	@${DUNE} uninstall

static/dune:
	@${MAKE} -C static dune

.PHONY: travis docker-images publish-docker-images

# Generates up-to-date translation template for lang % from the sources
LANGS = $(patsubst translations/%.po,%,$(wildcard translations/*.po))
translations/$(LANGS:=.pot):
	@for f in $(LANGS); do echo >> translations/$$f.po; done
	@rm -f translations/*.pot
	@${DUNE} clean ${DUNE_ARGS}
	-rm -f ${INDEX_ODOC_PATH}
	@DUMP_POT=1 ${DUNE} build ${DUNE_ARGS} -j 1
	@for f in $(LANGS); do \
	  mv translations/$$f.pot translations/$$f.pot.bak; \
	  msguniq translations/$$f.pot.bak > translations/$$f.pot; \
	  rm translations/$$f.pot.bak; \
	done

# Updates existing translations (.po) for the latest source template
update-%-translation: translations/%.pot
	@msgmerge -U translations/$*.po translations/$*.pot
	@rm -f translations/$*.pot

opaminstall: install

REPO ?= demo-repository

testrun: build install
	rm -rf www/css
	learn-ocaml build --repo $(REPO) -j1
	rm -rf www/css
	ln -s ../static/css www
	LEARNOCAML_SERVER_NOCACHE=1 learn-ocaml serve

docker-images: Dockerfile learn-ocaml.opam
	@rm -rf docker
	@git clone . docker
	@cp Dockerfile docker
	@docker build -t learn-ocaml-compilation --target compilation docker
	@docker build -t learn-ocaml --target program docker
	@docker build -t learn-ocaml-client --target client docker
	@echo "Use with 'docker run --rm -v \$$PWD/sync:/sync -v \$$PWD:/repository -p PORT:8080 learn-ocaml -- ARGS'"

VERSION = $(shell opam show ./learn-ocaml.opam -f version)

publish-docker-images: docker-images
	docker tag learn-ocaml ocamlsf/learn-ocaml:$(VERSION)
	docker tag learn-ocaml ocamlsf/learn-ocaml:dev
	docker tag learn-ocaml ocamlsf/learn-ocaml:latest
	docker image push ocamlsf/learn-ocaml:$(VERSION)
	docker image push ocamlsf/learn-ocaml:dev
	docker image push ocamlsf/learn-ocaml:latest

clean:
	@${DUNE} clean
	-rm -f translations/$*.pot
	@${MAKE} -C static clean
	-rm -rf www
	-find . -name "*~" -delete
	-rm -f ${INDEX_ODOC_PATH}

travis: # From https://stackoverflow.com/questions/21053657/how-to-run-travis-ci-locally
	BUILDID="build-$$RANDOM";					\
	INSTANCE="travisci/ci-garnet:packer-1512502276-986baf0";	\
	docker run --name $$BUILDID -dit $$INSTANCE /sbin/init &&	\
	docker exec -it $$BUILDID bash -l

.PHONY: static-binaries
static-binaries:
	./scripts/static-build.sh

BINARIES = src/main/learnocaml_client.bc.exe src/main/learnocaml_main.bc.exe src/main/learnocaml_server_main.exe
SEXP = src/main/linking_client.sexp src/main/linking_main.sexp src/main/linking_server.sexp

.PHONY: detect-libs
# HINTS to rely on this target using GitHub Action logs:
# * Open (old successful run, new run) for "build-macos.yml"
# * Search for the string "# make detect libs", then Compare
# * Open (old successful run, new run= for "build-and-test.yml (Dockerfile.test-server)"
# * Search for the string "# make detect libs", then Compare
#
# * Update "src/main/linking_flags.sh" (common) or "src/main/dune" (ad-hoc) or:
#
# * Open (old successful run) for "static-builds.yml"
# * Search for the string ";; generated by ./linking_flags.sh"
# * Remember that "m" and "pthread" are built-in, then Conclude
#
# * Update "src/main/linking_flags.sh" (common) or "src/main/dune" (ad-hoc).
detect-libs:
	# Running: make LINKING_MODE=dynamic OCAMLPARAM="_,verbose=1"
	$(RM) $(addprefix _build/default/,$(BINARIES) $(SEXP))
	+sort=false; \
	baseid=$$(mktemp -d "$$PWD/detect-libs.XXXXXX"); \
	$(MAKE) LINKING_MODE=dynamic OCAMLPARAM="_,verbose=1" > $$baseid/verb.log 2>&1 || exit 1; \
	echo "# make detect-libs"; \
	for bin in $(BINARIES); do \
	  base=$${bin#src/main/}; base=$${base%.*}; \
	  grep -e "'$$bin'" $$baseid/verb.log > $$baseid/verb.$$base.log; \
	  printf "%s: " "$$base"; \
	  ( sed -e "s/'//g; s/ /\\$$(printf '\n/g')" $$baseid/verb.$$base.log | grep -e "^-l" | \
	    if [ "$$sort" = true ]; then printf "(sorted) "; sort -u; else cat; fi | xargs echo ); \
	done; echo; \
	cat $$baseid/verb.*.log; \
	$(RM) $$baseid/verb*log; \
	rmdir $$baseid
	# Overwrote: $(addprefix _build/default/,$(BINARIES) $(SEXP))
