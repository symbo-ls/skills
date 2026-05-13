# Platform Binding — Symbols stack constraints

This template is for tenants running on the **Symbols platform**. Every execution-capable agent (epic agents, UX, UI Design, QA when it edits fixtures) MUST honor the rules here. They are non-negotiable.

Symbols MCP is the source of truth for the framework + design system at runtime — agents call it to refresh rules before any code change. The rules below are a compressed reference; the canonical version lives in MCP.

## Required workflow on every code task

Before generating or editing any DOMQL / smbls code:

1. **`mcp__symbols-mcp__get_project_context`** — resolves owner / key / env from the project's `symbols.json`.
2. **`mcp__symbols-mcp__get_project_rules`** — bundles FRAMEWORK + DESIGN_SYSTEM + RULES + COMPONENTS + DEFAULT_COMPONENTS + SYNTAX + PATTERNS + SNIPPETS + SHARED_LIBRARIES + FRANKABILITY + FRANK_FIX_WORKFLOW + COMMON_MISTAKES + LEARNINGS + DEFAULT_PROJECT. Read it all. Don't skim past `COMPONENTS.md` / `DEFAULT_COMPONENTS.md`.
3. **`mcp__symbols-mcp__generate_component` / `generate_page`** for new code — returns a compliant scaffold.
4. **`mcp__symbols-mcp__audit_component(code)`** after each component — inline validator.
5. **`mcp__symbols-mcp__audit_and_fix_frankability(dir)`** before committing.

The pre-edit hook on a Symbols project BLOCKS edits to `*.js` until step 2 has run. Don't fight it; just run it.

## Built-in components — reuse, never redefine

Every Symbols project inherits `@symbo.ls/default-config`:

- **Atoms** — `Block`, `Box`, `Flex`, `Grid`, `Hgroup`, `Img`, `Picture`, `Video`, `Iframe`, `Text`, `Form`, `Svg`, `Shape`, `Theme`, `InteractiveComponent`.
- **Components** — `Avatar`, `Button`, `Dialog`, `Dropdown`, `Link`, `Notification`, `Range`, `Select`, `Tooltip`, `Icon`, `Input`.

DOMQL auto-extends by key. Just write the bare key:

```js
// CORRECT — renders built-in
Avatar: { src: 'me.jpg' }

// CORRECT — multi-instance
Avatar_1: { src: 'a.jpg' }
Avatar_2: { src: 'b.jpg' }

// WRONG — redefining a built-in
Avatar: { tag: 'div', borderRadius: '50%' }

// WRONG — redundant extends when key already matches
Avatar: { extends: 'Avatar', src: 'me.jpg' }
```

The design system (colors, typography, spacing, themes) IS meant to be branded per tenant via `designSystem/` token files. Components are NOT meant to be reskinned at the consumer — visual variants are produced by token swap + theme, not by rewriting the component.

## Reuse — 3-tier search order BEFORE creating

DOMQL bare-key resolver walks:
1. Framework built-ins (`@symbo.ls/default-config`).
2. Shared libraries linked via `sharedLibraries.js` at the project root.
3. Current project's `components/`, `snippets/`, `functions/`, `methods/`.

So `Card: {}` works whichever tier defines `Card`.

### Discovery checklist before writing

```bash
# What shared libraries are linked?
cat sharedLibraries.js

# npm mode or local mode?
grep -E 'sharedLibrariesMode' symbols.json

# Library files (READ-ONLY — never edit; override locally instead):
#   npm mode    → node_modules/<package>/components/
#   local mode  → .symbols_local/libs/<owner>/<key>/components/
#   destDir     → custom path per entry in sharedLibraries.js

# Local components / snippets:
grep -rE '^export const [A-Z]' components/ snippets/

# Functions / methods:
grep -rE '^export (const|function) ' functions/ methods/

# Semantic search:
mcp__symbols-mcp__search_symbols_docs(query)
```

Most projects use `system/default` shared library (~127 common components). Check there first.

### Override pattern

When a library component needs a tweak in the consumer:

```js
// components/Card.js in your project
export const Card = { extends: 'Card', ...overrides }
```

This shadows the library `Card` for THIS project only. The library source stays untouched.

### Reuse rules

- Any tier covers ~80% of what you need? Use bare-key reference + override differing props.
- Writing the 3rd near-duplicate locally? STOP, extract to `components/<Name>.js`, replace duplicates with bare-key references.
- Two pages compute the same thing? Extract to `functions/<name>.js`, invoke via `el.call('name', ...)`. NEVER import between project files.

### Frank-discovered folders (everything else is silently dropped at publish)

`components/`, `snippets/`, `pages/`, `functions/`, `methods/`, `designSystem/`, `files/`, `assets/`.

NEVER use `utils/`, `lib/`, `helpers/` — they're dropped at publish time.

## DOMQL v3.14 syntax — required

This stack runs smbls v3.14. v3 syntax is not acceptable. The flat-access model is the single most important syntactic shift:

### Flat props (no `el.props.*`)

```js
// WRONG — v3
isActive: (el, s) => el.props.src === s.src
el.props.text

// CORRECT — v3.14
isActive: (el, s) => el.src === s.src
el.text
```

### Flat event handlers (no `el.on.*`)

```js
// WRONG — v3
{ on: { click: (e, el, s) => ... } }
{ on: { init: (el, s) => ... } }
el.on.click()

// CORRECT — v3.14
{ onClick: (e, el, s) => ... }
{ onInit: (el, s) => ... }
el.onClick()
```

### HTML attributes are top-level props

```js
// WRONG — unnecessary attr wrapper
Input: { attr: { placeholder: 'Search…', type: 'text' } }

// CORRECT — flat props
Input: { placeholder: 'Search…', type: 'text' }
```

Reserve `attr: { }` for attributes that are NOT first-class props (rare edge cases).

### Function access — `el.call` / `this.call`

NEVER import project functions into a DOMQL component.

```js
// WRONG — raw sibling import
import { findMe } from '../functions/index.js'
text: (el, s) => findMe(s).avatar

// CORRECT — call via registered functions
text: (el, s) => el.call('findMe', s).avatar
```

### Key-based auto-extend

```js
// WRONG — redundant
Icon: { extends: 'Icon', name: 'arrow' }
Icon1: { extends: 'Icon', name: 'home' }, Icon2: { extends: 'Icon', name: 'search' }

// CORRECT
Icon: { name: 'arrow' }
Icon_1: { name: 'home' }, Icon_2: { name: 'search' }   // _N suffix ignored for resolution

// PREFERRED — name the key to match
AppNavbar: {}   // instead of AppNav: { extends: 'AppNavbar' }
```

## Design system — token-only values

- Design system keys are always lowercase: `color`, `theme`, `typography`, `spacing`, `motion`.
- ALL values use design system tokens — no raw px, no hex, no rgba.
- Color shading uses modifiers: `'blue.7'`, `'gray+50'`. NEVER Tailwind-style palettes.
- CSS nesting uses real selectors: `'@dark': { ':hover': {} }`. NEVER chained selectors like `'@dark :hover'`.
- `cases.js` at root level — NOT inside `designSystem/`.

## Frankability hard rules (FA0xx-FA5xx)

Full list in `FRANKABILITY.md` (via `get_project_rules`). The ones you'll trip over most:

- **FA001** — no sibling imports. Use `el.call('fnName')` or PascalCase key refs.
- **FA101** — `el.X`, never `el.props.X`.
- **FA102** — `el.onClick`, never `el.on.click`.
- **FA105** — flat HTML attrs (no `attr: { }`).
- **FA106** — `(el, s)` signature; never destructure `(el, { state })`.
- **FA201** — mutable state lives in `globalScope.js`.
- **FA204** — one-shot const → `scope: { X }`.
- **FA206** — dynamic `await import('pkg')` in handlers; NEVER top-level static.
- **FA207** — nested helpers via `const x = () => {}`; NEVER `function x () {}`.
- **FA208** — `globalScope.js` never cross-imports from peers.
- **FA209** — `dependencies.js` = runtime importmap only.
- **FA210** — bypass-mode handlers guard `el.node` and `s.parent?` / `s.root?`.
- **FA513** — no `window.update()` / `document.update()`.
- **FA514** — no `window.__projectInit` module-side-effect bridges.

The pre-commit hook runs `audit_and_fix_frankability` on changed dirs; agents must run it explicitly before commit, not rely on hook fallback.

## Shared libraries — read-only without explicit permission

`sharedLibraries.js` at the project root lists every shared library in scope. Shared-library source code is READ-ONLY from a consumer ticket. Editing it modifies every consumer, not just the one you're in.

**Rule:** read freely for context, never edit unless the user / Chuvak explicitly authorized.

If a fix truly requires a shared-library change, return `blocked_external` to Temo — the ticket needs routing to whichever epic OWNS that shared library (typically UI Design for visual primitives; an upstream epic for cross-cutting non-visual primitives).

## Plugins — `@symbo.ls/*`

The platform ships a set of plugins that hook into DOMQL element lifecycle. Common ones agents interact with:

- **`@symbo.ls/fetch`** — declarative data binding. Components declare `fetch: [{ from: '<entity>.<sub>', method: 'list', as: '~/result' }]`. Routed through the SDK adapter, never raw `fetch()`.
- **`@symbo.ls/frank`** — build-time component validator + publisher. `audit_and_fix_frankability` invokes this.
- **`@symbo.ls/brender`** — bypass-mode render plugin. Handlers that opt into bypass must guard `el.node` and `s.parent?`.
- **`@symbo.ls/funcql`** — function query language for typed RPC-ish dispatch.
- **`@symbo.ls/freestyler`** — style transform.
- **`@symbo.ls/keyflows`** — keyboard flow primitives.
- **`@symbo.ls/sync`** — collab primitives.
- **`@symbo.ls/helmet`** — head-tag management.
- **`@symbo.ls/polyglot`** — i18n primitives.

When a ticket implies adding to or modifying plugin behavior, route to the plugins epic; never patch plugin source from a consumer ticket.

## SDK-only backend access

Every backend query goes through `@symbo.ls/sdk`. NEVER use raw `fetch()`, `socket.io-client`, `axios`, or any other transport from project code.

- `sdk.execute(entity, op, args)` for REST.
- `sdk.subscribeUserEvents` for sockets.
- `CollabClient` for project-collab.
- DOMQL data dependencies declared via `fetch: [...]` route through the SDK adapter automatically.

If the SDK is missing a method you need, add it to the SDK (route through the SDK epic agent via `blocked_external`), don't bypass with a raw fetch.

## Publishing

Push to your repo's main branch. CI handles the rest. Do NOT run `bun publish`, `npm publish`, `bun version`, `lerna publish`, or any equivalent. The release manager owns version ripple, registry routing, and downstream fan-out.

Read `RELEASE_PLAN.md` (at the platform release-manager) before doing anything that smells like a release.

## Bun, not npm

The monorepo uses **bun** as package manager + script runner. Substitute:

| npm / npx          | bun                                  |
|--------------------|--------------------------------------|
| `npm install`      | `bun install`                        |
| `npm install <p>`  | `bun add <p>`                        |
| `npm run <s>`      | `bun run <s>` (or `bun <s>`)         |
| `npm test`         | `bun test`                           |
| `npx <bin>`        | `bunx <bin>`                         |

Lockfile is `bun.lock`, not `package-lock.json`. Don't generate `package-lock.json`. If you find one, flag it as regression.

## Self-check before finishing

Before calling `open_resolution_ticket`:

1. `mcp__symbols-mcp__audit_component` ran on every component touched; violations addressed.
2. `mcp__symbols-mcp__audit_and_fix_frankability` ran on changed dirs; clean.
3. No raw px / hex / rgba in shipped code.
4. No sibling imports between project files.
5. No `el.props.X` or `el.on.X` access.
6. No HTML attrs wrapped in `attr: { }`.
7. No project file in `utils/` / `lib/` / `helpers/`.
8. Tests for the touched code pass.
9. Resolution JSONB includes `triggers_mcp_update=true` if you added / renamed / changed contract of any MCP-doc-relevant surface (routes, SDK methods, schema additions, auth flow, Stripe contracts, edge-fn contracts).

## What this binding does NOT cover

- Tenant-specific scope assignments (live in `SCOPE_MAP.md`).
- Per-tenant approval gate config (`APPROVAL_GATES.md` + `agents.config.yaml`).
- Tenant-specific epic catalog (`agents.config.yaml > epics[]`).

This binding covers the platform-level constraints that apply to EVERY tenant adopting this template, because they all sit on the same Symbols stack.
