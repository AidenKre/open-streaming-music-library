# open-streaming-music-library (OSML)

OSML is a self-hosted music server and an app that plays from it. You run the
server on a computer of your own, meant to be modest hardware such as an old
laptop, put your music into its import folder, and listen with the app. The
aim is that anyone, not only power users, can own and stream their own music
instead of renting it from a big streaming service.

## What is here

- [`backend/`](backend/README.md): the server (Python, FastAPI, SQLite),
  written for Linux and macOS (POSIX only).
- [`frontend/`](frontend/README.md): the app (Flutter).

## Getting started

1. Set up and start the server: [`backend/README.md`](backend/README.md)
   (prerequisites, the master admin in `.env`, the start command).
2. Put music (`.mp3`, `.wav`, `.flac`, `.m4a`, or a `.zip`, `.rar`, `.tar` or
   `.tar.gz` of them) into the master admin's import folder (`backend/import/`
   by default). The server imports it on its own and moves each imported file
   into its library folder (`backend/music/` by default), so put in copies,
   not your only files.
3. Build and run the app: [`frontend/README.md`](frontend/README.md). On its
   first screen, enter the server's address (for example
   `http://192.168.1.20:8000`) and log in as the master admin.

## Status

OSML is built by one person and is early work. One server can have several
users, each with their own library. Both the server and the app assume a fresh
install: a database written by an earlier version is refused, on both sides,
and there is no way to upgrade it yet. Until the first release the server's
schema is still changed in place without a new version number, so the server
cannot tell a data folder made by an earlier build: after updating the server,
start with a new data folder. The app has been run on macOS only so far.

Licence: MIT (see [`LICENSE`](LICENSE)).
