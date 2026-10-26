.PHONY: build test package check-package check-distribution install-helper
build:
	swift build -c release --disable-sandbox
test:
	swift test --disable-sandbox
	node --test Tests/*.test.cjs
	python3 Tests/native_integration.py
package:
	python3 scripts/package-extension.py
check-package: package
	python3 Tests/package_smoke.py
check-distribution: check-package
	python3 Tests/distribution_smoke.py
install-helper:
	bash scripts/install-helper.sh
