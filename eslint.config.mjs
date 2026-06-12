/**
 * ESLint flat config — single source of lint truth for this repo.
 *
 * This repo is markdown skill templates only — there is no JavaScript to
 * lint (the `lint` npm script is intentionally a no-op echo). This file
 * exists so the repo matches the monorepo-wide approach (flat config
 * everywhere) and is ready if JS is ever added.
 */

/** @type {import('eslint').Linter.Config[]} */
export default [
  {
    ignores: [
      '**/node_modules/**',
      '**/dist/**',
      '**/.parcel-cache/**'
    ]
  }
]
