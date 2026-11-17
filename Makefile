# One command per step; reviewers need only Docker and make.
#   make deb    build nginx from source and write the .deb to dist/
#   make clean  delete dist/

# These targets are command names, not files make should look for.
.PHONY: deb clean

deb:
	docker build --output type=local,dest=dist build/

clean:
	rm -rf dist
