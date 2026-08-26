CONFIG ?= debug
APP    := MacEQ.app
PID     = $$(pgrep -x maceq)

.PHONY: build bundle run stop up down bypass log clean

build:
	swift build -c $(CONFIG)

bundle: build
	CONFIG=$(CONFIG) ./scripts/bundle.sh

run: bundle
	open $(APP)

stop:
	@kill -TERM $(PID) 2>/dev/null || echo "not running"

up:
	@kill -USR1 $(PID)

down:
	@kill -USR2 $(PID)

bypass:
	@kill -HUP $(PID)

log:
	@tail -f /tmp/maceq.log

clean:
	rm -rf .build $(APP)
