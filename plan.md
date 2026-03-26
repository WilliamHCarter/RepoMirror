# RepoMirror — Customization Plan

## Easy Wins (config changes, no template overrides)

### 1. Landing page redirect to user profile
Set `LANDING_PAGE=custom` pointing to `/{username}` so visitors hit
the profile page instead of the generic Forgejo homepage.
- docker-compose.yml env vars
- setup.sh: auto-set based on FORGEJO_ADMIN_USER

### 2. Enable contribution heatmap
Already on by default, but explicitly set to be safe.
- docker-compose.yml: `FORGEJO__service__ENABLE_USER_HEATMAP=true`

### 3. Custom branding hooks
Mount a `custom/` directory into the container so users can drop in:
- `public/assets/img/logo.svg` (site logo)
- `public/assets/img/favicon.svg` (browser tab icon)
- `public/assets/css/theme-repomirror.css` (custom theme)
- `templates/custom/header.tmpl` (CSS injection)
- `templates/custom/footer.tmpl` (JS injection)
Create the directory structure in setup.sh with placeholder files.

### 4. Disable registration + explore for single-user
Hide the "Sign In" and "Register" buttons and explore page for
visitors. The owner is the only real user.
- `FORGEJO__service__DISABLE_REGISTRATION=true` (already done)
- `FORGEJO__service__REQUIRE_SIGNIN_VIEW=false` (repos stay public)
- `FORGEJO__other__SHOW_FOOTER_VERSION=false` (cleaner look)

### 5. Default to dark theme
Set `forgejo-dark` as the default theme since it looks better as a
portfolio-style page.
- `FORGEJO__ui__DEFAULT_THEME=forgejo-dark`

### 6. .profile repo auto-creation
After migration, auto-create a `.profile` repo with a starter
README.md that renders on the user's profile page. This is the
"MySpace wall" — give them a template to customize.

---

## Hard Tasks (template overrides, SSO, frontend work)

### 7. SSO — "Sign in with GitHub"
Let visitors authenticate with their GitHub account instead of
creating a Forgejo account. Requires:
- User creates a GitHub OAuth App (Client ID + Secret)
- setup.sh prompts for these and runs `forgejo admin auth add-oauth`
- Enable auto-provisioning so first-time GitHub logins just work
- Optionally disable password login (`ENABLE_INTERNAL_SIGNIN=false`)
**Risk:** Moderate. CLI automation is straightforward but adds
setup complexity. Only useful if the mirror is publicly accessible.

### 8. Template overrides for cleaner single-user UI
Strip multi-user/forge chrome that doesn't apply:
- Hide "Explore" nav link
- Hide "New Repository" / "New Organization" for non-admins
- Simplify footer
**Risk:** High maintenance. Templates break on Forgejo upgrades.
Watchtower auto-updates daily, so overrides can break overnight.

### 9. Custom portfolio frontend
Build a lightweight SPA/static site that sits in front of Forgejo:
- Pulls data from Forgejo API (repos, profile, heatmap)
- Custom design not constrained by Forgejo templates
- Forgejo still serves git operations and API
- Caddy/cloudflared routes `/` to the frontend, `/api` + git to Forgejo
**Risk:** Significant new code. But upgrades never break it since
it only talks to the stable API.

### 10. Commit graph / contribution stats
Richer activity visualization beyond the built-in heatmap:
- Language breakdown across all repos
- Commit frequency charts
- "Most active repos" widget
**Risk:** Requires either template overrides (fragile) or the
custom frontend approach (#9). Best done as part of #9.
