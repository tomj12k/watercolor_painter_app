.PHONY: test build app run

test:
	swift test

build:
	swift build --product WatercolorStudio

app:
	scripts/package_app.sh

run:
	swift run WatercolorStudio
