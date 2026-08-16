.PHONY: test build app distribution run

test:
	swift test

build:
	swift build --product WatercolorStudio

app:
	scripts/package_app.sh

distribution:
	scripts/package_distribution.sh

run:
	swift run WatercolorStudio
