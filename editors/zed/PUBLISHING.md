# Publishing this extension in Zed's extensions

For the maintainer. Zed lists an extension once a pull request adds it to
[zed-industries/extensions](https://github.com/zed-industries/extensions); Zed's
[publishing guide](https://zed.dev/docs/extensions/publishing/publishing-guide) has the details.

## Once

1. **This repository on GitHub, public**: `github.com/foxoman/nedls-zed`, with this folder as its `main` branch.
2. **Try it in Zed** at the commit you will submit (Zed asks for that): `zed: install dev extension`, pick the
   folder, open a Nim file with `nedls` on `PATH` — the server starts (Zed's log: `zed: open log`).
3. **Fork** `zed-industries/extensions` to your own account (not an organisation, so Zed's people can push to the
   pull request), then:

   ```sh
   git clone https://github.com/foxoman/extensions && cd extensions
   git submodule init && git submodule update --depth 1
   git submodule add https://github.com/foxoman/nedls-zed.git extensions/nedls-language-server
   ```

   and add to `extensions.toml`:

   ```toml
   [nedls-language-server]
   submodule = "extensions/nedls-language-server"
   version = "6.41.1"
   ```

   The version must be the one in this repository's `extension.toml` at that commit; the submodule's URL must be
   `https://`, and its commit on a branch.
4. **Sort** with `pnpm sort-extensions` (it orders `extensions.toml` and `.gitmodules`), commit, and open the pull
   request — one extension a pull request. Answer the reviewers within three weeks.

## Each new version

1. Here: the new version in `extension.toml` and `Cargo.toml` (ned's version), commit and push to `main`.
2. In your fork of `zed-industries/extensions`:

   ```sh
   git -C extensions/nedls-language-server pull origin main
   ```

   the same version in `extensions.toml`, commit, pull request.

## What Zed checks

- the id (`nedls-language-server`): unique, kebab-case, saying what it is (`-language-server`), without "zed" or
  "extension";
- a licence it accepts, beside `extension.toml` (`LICENSE`: the GPL 3);
- the language server is not in the extension: it is found on the user's `PATH` (or named in Zed's settings),
  never bundled.
