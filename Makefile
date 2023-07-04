default: build

build-codecore:
	cd ./Sources/CodeCore/src && npm install && ./node_modules/.bin/rollup -c

open-codecore:
	open ./Sources/CodeCore/src/build/index.html

build-swift:
	swift build -v

clean:
	swift package clean

build: build-codecore build-swift

#format:
#	swift-format --in-place --recursive --configuration ./.swift-format.json ./

.PHONY: clean test format build-codecore open-codecore
