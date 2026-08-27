export function escapeHtml(value) {
  return String(value)
    .replaceAll('&', '&amp;')
    .replaceAll('<', '&lt;')
    .replaceAll('>', '&gt;')
    .replaceAll('"', '&quot;')
    .replaceAll("'", '&#39;');
}

const STYLE = `
  body { font-family: -apple-system, system-ui, sans-serif; max-width: 720px; margin: 40px auto; padding: 0 16px; color: #1a1a1a; }
  nav { margin-bottom: 24px; font-size: 14px; }
  nav a { margin-right: 12px; }
  table { border-collapse: collapse; width: 100%; margin: 12px 0; }
  th, td { text-align: left; padding: 6px 10px; border-bottom: 1px solid #ddd; font-size: 14px; }
  form.inline { display: inline; }
  input, select { padding: 6px; margin: 4px 0; }
  button { padding: 6px 12px; cursor: pointer; }
  .error { color: #b00020; }
  .warn { background: #fff3cd; border: 1px solid #d4a72c; padding: 12px; border-radius: 4px; }
  .muted { color: #666; font-size: 13px; }
  pre { background: #f5f5f5; padding: 12px; overflow-x: auto; }
  .app-link { display: inline-flex; align-items: center; gap: 9px; }
  .app-logo { width: 36px; height: 36px; border-radius: 9px; object-fit: cover; flex: 0 0 auto; }
  .app-logo-large { width: 80px; height: 80px; border-radius: 18px; }
  .app-logo-fallback { display: inline-flex; align-items: center; justify-content: center; background: #e8ecf6; color: #2d4677; font-weight: 700; }
  .app-profile { display: flex; align-items: center; gap: 16px; margin: 8px 0 20px; }
  .app-profile h2, .app-profile p { margin: 0 0 4px; }
`;

export function renderPage(title, bodyHtml, { user } = {}) {
  const nav = user
    ? `<nav><a href="/">Dashboard</a>${user.is_root ? '<a href="/admin-log">Admin log</a>' : ''}<form class="inline" method="post" action="/auth/logout"><button type="submit">Logout (${escapeHtml(user.email)})</button></form></nav>`
    : `<nav><a href="/auth/login">Login</a><a href="/auth/register">Register</a></nav>`;
  return `<!doctype html>
<html>
<head><meta charset="utf-8"><title>${escapeHtml(title)}</title><style>${STYLE}</style></head>
<body>
${nav}
<h1>${escapeHtml(title)}</h1>
${bodyHtml}
</body>
</html>`;
}
