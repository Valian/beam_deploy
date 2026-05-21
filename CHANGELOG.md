# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.0.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

<!-- %% CHANGELOG_ENTRIES %% -->

## Unreleased

### Added

- Added a self-deploying Phoenix example app that demonstrates blue-green release swaps with live build logs.

### Fixed

- Preserved the active extracted release directory during cleanup so swapped peers keep serving static assets.

## 0.1.0 - 2026-05-19

### Added

- Initial experimental release with single-host blue-green release swaps through OTP `:peer`.
- Added manual in-process hot upgrades from local `mix release` tarballs.
- Added parent-node handoff helpers and cutover callbacks.
