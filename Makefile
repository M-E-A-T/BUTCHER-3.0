.PHONY: start build test

# Build the release binary, then run the server and open the UI in the browser.
start: build
	engine/target/release/audio-server --open

build:
	cd engine && cargo build --release -p server

test:
	cd engine && cargo test && cargo clippy --all-targets
