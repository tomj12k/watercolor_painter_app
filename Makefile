.PHONY: test build app distribution qualify run

test:
	swift test

build:
	swift build --product WatercolorStudio

app:
	scripts/package_app.sh

distribution:
	scripts/package_distribution.sh

qualify:
	scripts/qualify_release.sh

run:
	swift run WatercolorStudio
