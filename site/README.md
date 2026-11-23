# DeckOS website

Static marketing site for DeckOS, published at <https://itskavin.github.io/DeckOS/>.
No build step: `index.html`, `styles.css`, `main.js` and the files next to them are served as is.

```sh
npx --yes http-server site -p 8300 -c-1   # preview at http://localhost:8300/
```

- Asset paths are relative, so the site works under the `/DeckOS/` project-pages path.
- Brand icons are inlined in `index.html` from Simple Icons 15.0.0 (CC0). Trademarks belong to their owners.
- `logo.png`, `favicon-32.png`, `icon-512.png`, `icon-maskable-512.png` and `apple-touch-icon.png` come
  from `branding/generate.py`, which also swaps the logo in the header of `og.png`. The rest of `og.png` was
  rendered from the page with headless Chrome; re-render it if the hero changes.
- `main.js` asks the GitHub API for the latest release and points the download buttons at the matching
  files (`*Setup.exe`, `*.app.zip`, `*linux-x64.tar.gz`, `*.apk`). Until a release exists the buttons link to
  the releases page, and the API call logs a 404 in the console.

## Deploying together with the docs

A repository has one GitHub Pages site, so `.github/workflows/site.yml` (this folder) and
`.github/workflows/pages.yml` (MkDocs docs) must not both deploy. Keep one workflow that builds the docs
into `docs/` of this site:

1. In `website/mkdocs.yml` set `site_url: https://itskavin.github.io/DeckOS/docs/` and
   `site_dir: ../_site/docs` (it already builds to `../_site/docs`).
2. In `pages.yml`, replace the step that copies `website/landing/` with `cp -r site/. _site/`, add
   `'site/**'` to the `paths:` filter, and delete `site.yml` (or the reverse: move the MkDocs build into `site.yml`).
3. Retire `website/landing/` once this site replaces it.
