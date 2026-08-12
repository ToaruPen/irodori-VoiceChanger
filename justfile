default:
    @just --list

bootstrap:
    npm install

format:
    swift format format --in-place --recursive Sources Tests Package.swift

format-check:
    swift format lint --strict --recursive Sources Tests Package.swift

lint:
    swiftlint lint --strict

build:
    swift build -Xswiftc -warnings-as-errors

test:
    swift test

test-cov:
    bash scripts/coverage.sh

secret-scan:
    npm exec -- secretlint .

build-app:
    bash scripts/build-app.sh

justfile-check:
    bash scripts/check-justfile.sh

check: format-check lint build test-cov secret-scan justfile-check build-app

config *args:
    just _cli config {{args}}

doctor *args:
    just _cli doctor {{args}}

devices *args:
    just _cli devices {{args}}

run *args:
    just _cli run {{args}}

_cli *args:
    just build-app
    dist/IrodoriVoiceChanger.app/Contents/MacOS/irodori-voicechanger {{args}}

replay *args:
    just _cli replay {{args}}

report *args:
    just _cli report {{args}}
