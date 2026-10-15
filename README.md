# MCloud conventions

The shared conventions, files and checks of the Zebrunner MCloud repositories: [appium](https://github.com/zebrunner/appium), [mcloud-android-connector](https://github.com/zebrunner/mcloud-android-connector), [mcloud-ios-connector](https://github.com/zebrunner/mcloud-ios-connector), [mcloud-grid](https://github.com/zebrunner/mcloud-grid) and [mcloud-agent](https://github.com/zebrunner/mcloud-agent). The rules themselves are in [CONVENTIONS.md](CONVENTIONS.md).

## How it works

| Piece | What it does |
| --- | --- |
| the shared files | `CONVENTIONS.md`, `LICENSE`, `.shellcheckrc`, `.pymarkdown`, `tests/lib.sh`, `tests/lint.sh`, the debug mode and the logger of `shared/util/` with their tests; this repository uses them too |
| the shared blocks | the lines between `# >>> mcloud-conventions` and `# <<< mcloud-conventions` of `.editorconfig`, `.gitignore` and `tests/requirements-lint.txt`; the lines after them are the project part of every repository |
| `sync/targets.yml` | which repository gets which files, and the paths of a repository (e.g. `files/util/` of appium) |
| `sync/sync.py` | applies the files and blocks to a repository, writes `.mcloud-conventions` (their checksums) and opens or updates the pull request `mcloud-conventions-sync` into its `develop` |
| `.github/workflows/sync.yml` | runs the sync as the GitHub App `mcloud-conventions-sync` on every merge into `main` (and by hand: Actions, Sync, Run workflow) |
| `.mcloud-conventions` | in every repository: the checksums of its shared files and blocks; `make lint` fails when one of them is changed there |
| `.github/workflows/lint.yml` | the reusable `lint` job of the repositories: `uses: zebrunner/mcloud-conventions/.github/workflows/lint.yml@v1` |

## Change a convention or a shared file

1. Open a pull request here: CI runs the checks of this repository and `sync-preview` shows the changes the sync would make in every repository.
2. Merge it: the sync opens (or updates) a pull request in every repository it changes, their CI checks the change there.
3. Review and merge those pull requests.

A change of `.github/workflows/lint.yml` reaches the repositories through the tag `v1`: move it to the new commit after the merge (`git tag -f v1 && git push -f origin v1`) when the change is compatible, an incompatible change gets `v2` and the repositories switch to it.

## The access of the sync

The sync pushes to the other repositories, so it acts as a GitHub App: the workflow gets a token of the App installation for an hour, the App is not bound to a person, and its pull requests run the CI of the repositories.

1. Create the App: the organization Settings, Developer settings, GitHub Apps, New GitHub App:
   - name: `mcloud-conventions-sync`, homepage: `https://github.com/zebrunner/mcloud-conventions`;
   - Webhook: off (clear Active);
   - Repository permissions: Contents: Read and write, Pull requests: Read and write (Metadata: Read-only comes with them);
   - Where can this GitHub App be installed: Only on this account.
2. Generate a private key of the App (the `.pem` file is downloaded) and copy its App ID (the About of the App).
3. Install the App (Install App, zebrunner): Only select repositories, the repositories of `sync/targets.yml`.
4. Here, Settings, Secrets and variables, Actions: the variable `CONVENTIONS_SYNC_APP_ID` with the App ID and the secret `CONVENTIONS_SYNC_APP_PRIVATE_KEY` with the content of the `.pem` file:

   ```bash
   gh variable set CONVENTIONS_SYNC_APP_ID -R zebrunner/mcloud-conventions --body "<App ID>"
   gh secret set CONVENTIONS_SYNC_APP_PRIVATE_KEY -R zebrunner/mcloud-conventions < mcloud-conventions-sync.private-key.pem
   ```

5. Run the Sync workflow (Actions, Sync, Run workflow): every repository is `up to date`.

A new repository of `sync/targets.yml` is added to the installation of the App (the organization Settings, GitHub Apps, mcloud-conventions-sync, Configure).

Without the App the sync takes the secret `CONVENTIONS_SYNC_TOKEN`: a fine-grained personal access token with the access to the repositories and the permissions Contents and Pull requests: Read and write. Without both the Sync workflow fails with a message, the rest works.

## Add a repository

1. In the repository: `.editorconfig`, `.gitignore` and `tests/requirements-lint.txt` with the markers of the shared block, `tests/lint_project.sh`, the `lint` job of the reusable workflow.
2. Here: the repository in `sync/targets.yml`; the App installed on it (Configure of the App in the organization Settings).
3. Run the Sync workflow: the pull request brings the shared files and `.mcloud-conventions`.

## Development

| Target | What it checks | Needs |
| --- | --- | --- |
| `make lint` | the shared `tests/lint.sh` with `tests/lint_project.sh` of this repository, ruff of the sync | Python 3; on macOS `brew install hadolint` |
| `make test` | `tests/sync_test.sh` (the sync with local repositories), the logger and the debug mode | bash, Python 3 |
| `make sync-preview` | the changes the sync would make in the repositories, nothing is pushed | Python 3, git |

`python3 sync/sync.py --repo zebrunner/appium --local zebrunner/appium=../appium` applies the shared files to a local checkout.

## License

[Apache License 2.0](LICENSE)
