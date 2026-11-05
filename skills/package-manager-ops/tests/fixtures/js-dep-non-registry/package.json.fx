{
  "name": "fixture-site",
  "private": true,
  "version": "1.0.0",
  "packageManager": "npm@11.19.0",
  "engines": {"node": ">=24 <25"},
  "dependencies": {
    "fixture-git": "git+https://example.invalid/fixture/git.git",
    "fixture-github": "github:example/fixture",
    "fixture-file": "file:../fixture-file",
    "fixture-link": "link:../fixture-link",
    "fixture-tar": "https://example.invalid/fixture.tgz"
  },
  "devDependencies": {"sass": "^1.93.2", "vite": "^8.0.10"}
}
