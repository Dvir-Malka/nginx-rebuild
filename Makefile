# One command per step; reviewers need only Docker and make.
#   make all    = make image
#   make deb    build nginx from source and write the .debs to dist/
#   make image  build the final image from dist/ (runs make deb first)
#   make scan   scan the image with Trivy and Grype, write scans/fixed-* and scans/DIFF.md
#   make vex-scan  same scans with vex/ applied, write scans/vex-*
#   make test   compare the image with upstream nginx:1.25-bookworm (test/compat_test.py)
#   make clean  delete dist/

# Name of the final image; override with: make image IMAGE=name:tag
IMAGE ?= nginx-rebuild:1.25.5

# These targets are command names, not files make should look for.
.PHONY: all deb image scan vex-scan test clean

all: image

deb:
	docker build --output type=local,dest=dist build/

# Depends on deb, so the image can never be built from missing or old .debs.
# A repeat run is fast because Docker reuses cached build steps.
image: deb
	docker build -f Containerfile -t $(IMAGE) .

# Scanner versions are pinned so results stay comparable with scans/baseline-*.
TRIVY = aquasec/trivy:0.76.2
GRYPE = anchore/grype:v0.121.3
# By default the scanners download today's vulnerability database. To repeat the
# committed scans with the database already in the cache volumes, run:
#   make scan TRIVY_DB_FLAGS="--skip-db-update --skip-java-db-update" GRYPE_DB_AUTO_UPDATE=false
TRIVY_DB_FLAGS ?=
GRYPE_DB_AUTO_UPDATE ?= true
# The scanners run as containers and read images through the Docker socket,
# so reviewers need only Docker. Reports land in scans/.
SCAN = docker run --rm -v /var/run/docker.sock:/var/run/docker.sock -v $(CURDIR)/scans:/out

# Depends on image, so we never scan a stale image.
scan: image
	$(SCAN) -v trivy-cache:/root/.cache $(TRIVY) image $(TRIVY_DB_FLAGS) \
	  --format json --output /out/fixed-trivy.json $(IMAGE)
	$(SCAN) -v trivy-cache:/root/.cache $(TRIVY) image $(TRIVY_DB_FLAGS) \
	  --format table --output /out/fixed-trivy.txt $(IMAGE)
	$(SCAN) -v grype-cache:/grype-db -e GRYPE_DB_CACHE_DIR=/grype-db \
	  -e GRYPE_DB_AUTO_UPDATE=$(GRYPE_DB_AUTO_UPDATE) \
	  $(GRYPE) $(IMAGE) -o table=/out/fixed-grype.txt -o json=/out/fixed-grype.json
	python3 scans/diff.py

# OpenVEX statement for our backported CVE. With it, the scanners move
# CVE-2026-15176 out of the results (Trivy: "Suppressed", Grype: ignoredMatches).
VEX = vex/nginx-CVE-2026-15176.openvex.json
SCAN_VEX = $(SCAN) -v $(CURDIR)/vex:/vex:ro

vex-scan: image
	$(SCAN_VEX) -v trivy-cache:/root/.cache $(TRIVY) image $(TRIVY_DB_FLAGS) \
	  --vex /$(VEX) --show-suppressed --format json --output /out/vex-trivy.json $(IMAGE)
	$(SCAN_VEX) -v trivy-cache:/root/.cache $(TRIVY) image $(TRIVY_DB_FLAGS) \
	  --vex /$(VEX) --show-suppressed --format table --output /out/vex-trivy.txt $(IMAGE)
	$(SCAN_VEX) -v grype-cache:/grype-db -e GRYPE_DB_CACHE_DIR=/grype-db \
	  -e GRYPE_DB_AUTO_UPDATE=$(GRYPE_DB_AUTO_UPDATE) \
	  $(GRYPE) $(IMAGE) --vex /$(VEX) -o table=/out/vex-grype.txt -o json=/out/vex-grype.json

# Boots upstream and $(IMAGE) side by side and compares their responses;
# exits non-zero on any mismatch. Depends on image, so we never test a stale
# image. Needs only python3 (standard library) besides Docker.
test: image
	IMAGE=$(IMAGE) python3 test/compat_test.py

clean:
	rm -rf dist
