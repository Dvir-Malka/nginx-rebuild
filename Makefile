# One command per step; reviewers need only Docker and make.
#   make all    = make image
#   make deb    build nginx from source and write the .debs to dist/
#   make image  build the final image from dist/ (runs make deb first)
#   make clean  delete dist/

# Name of the final image; override with: make image IMAGE=name:tag
IMAGE ?= nginx-rebuild:1.25.5

# These targets are command names, not files make should look for.
.PHONY: all deb image clean

all: image

deb:
	docker build --output type=local,dest=dist build/

# Depends on deb, so the image can never be built from missing or old .debs.
# A repeat run is fast because Docker reuses cached build steps.
image: deb
	docker build -f Containerfile -t $(IMAGE) .

clean:
	rm -rf dist
