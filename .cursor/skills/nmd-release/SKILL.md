---
name: nmd-release
description: >-
  Bumps ## Version in Nmd.toc, commits all changes, pushes main, and pushes an
  annotated git tag so GitHub Actions (BigWigs packager) deploys to Wago. Use when
  the user asks to release, ship, bump version, tag a release, or publish Nmd.
---

# Nmd release (version bump + tag deploy)

## Preconditions

- Git repo with `main` as release branch; remote `origin` set.
- `WAGO_API_TOKEN` already configured on GitHub (not required locally).
- Working tree: either clean before bump, or the user expects **all** changes included in this release commit.

## Steps (execute in order)

1. **Read** `Nmd.toc` and parse the line `## Version: ...` (trim value).

2. **Bump version** (default: **patch** — increment the last dot-separated numeric segment):
   - `1.0.4` → `1.0.5`
   - `1.0` → `1.1`
   - If the user asked for **minor** / **major**, bump the appropriate segment instead (semver: major.minor.patch).
   - If the user gave an explicit version (e.g. `2.0.0`), use that exactly.

3. **Edit** `Nmd.toc`: set `## Version:` to the new value (single line, same format as existing).

4. **Check** `git tag` / remote tags so the new tag does not already exist. Tag name must be `v` + the new version (e.g. version `1.0.5` → tag `v1.0.5`).

5. **Summarize changes** in **exactly one sentence** (imperative or neutral tone): what this release does vs the previous tag or prior state, based on `git diff`, file list, and context. No marketing filler.

6. **Stage and commit everything** the user wants released:
   - `git add -A`
   - `git commit -m "Release v<version> — <one-sentence summary>"`  
   Use a different subject only if the user specified an exact commit message (still include their wording; do not append “Made with” or tool credits).

7. **Push branch**: `git push origin main`  
   (If the default branch is not `main`, use that branch name.)

8. **Tag and push tag** (annotated tag, required by BigWigs packager conventions):
   - `git tag -a v<version> -m "v<version>"`  
     Optional: use `-m "v<version>" -m "<same one-sentence summary>"` for a tag body; never put “Made with” / “Made-with” there either.
   - `git push origin v<version>`

9. **Confirm** the tag push triggers `.github/workflows/release.yml` on GitHub (Actions tab).

## If something fails

- **Push rejected**: pull/rebase with user guidance; do not force-push unless the user explicitly asks.
- **Tag exists**: bump to a fresh version or delete the tag only if the user explicitly requests fixing a mistake.
- **No changes to commit** after editing only `.toc`: still commit the version bump if that is the only change.

## Do not

- Skip the tag push (without a tag, this project’s workflow does not deploy).
- Bump `## Interface:` unless the user asked to target a new WoW patch.
- Add any **“Made with …”**, **“Made-with …”**, or similar tool/editor attribution to commit messages, tag messages, release notes, or PR descriptions.
