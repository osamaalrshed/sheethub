// admin-detector.js — runs in every page load.
// 1) Admin detection: adds "is-admin" class to <body> when the logged-in
//    user has a NocoDB "super" or "org-level-creator" role, OR their
//    email is in the explicit ADMIN_EMAILS allowlist. The CSS overlay
//    skips every hide rule for these users, so they see the full
//    NocoDB UI (add field, settings, etc.).
// 2) Logo rebrand: replaces every NocoDB logo image with a "SheetsHub"
//    wordmark rendered as real HTML so it uses NocoDB's own page typography.
(function () {
  // Optional explicit allowlist by email — useful when a user is supposed
  // to see the admin UI but doesn't have super/creator role yet.
  const ADMIN_EMAILS = ['admin@nocodb.local'];

  function isAdmin(user) {
    if (!user) return false;
    // Role-based: anyone with super or org-level-creator gets the full UI.
    // roles can come back as either an object {role_name: true, ...} or
    // a comma-separated string like "org-level-creator,super".
    var r = user.roles;
    if (r && typeof r === 'object') {
      if (r.super === true || r['org-level-creator'] === true) return true;
    } else if (typeof r === 'string') {
      var parts = r.split(',').map(function (s) { return s.trim(); });
      if (parts.indexOf('super') >= 0 || parts.indexOf('org-level-creator') >= 0) return true;
    }
    // Email-based fallback / explicit grant.
    if (user.email && ADMIN_EMAILS.indexOf(user.email) >= 0) return true;
    return false;
  }

  function applyAdmin(user) {
    if (isAdmin(user)) {
      document.body.classList.add('is-admin');
    }
  }

  // NocoDB authenticates SPA requests via the xc-auth header, not cookies,
  // and stores the JWT in localStorage under the same "xc-auth" key.
  // Without sending the header, /api/v1/auth/user/me returns
  // {roles:{guest:true}}, which the detector reads as "not admin" — so
  // actual admins are stuck looking at the restricted UI. Forward the
  // token from localStorage as the header so /me returns the real user.
  function detect() {
    var headers = {};
    var t = localStorage.getItem('xc-auth');
    if (t) headers['xc-auth'] = t;
    fetch('/api/v1/auth/user/me', { credentials: 'include', headers: headers })
      .then(function (r) { return r.ok ? r.json() : null; })
      .then(function (user) { applyAdmin(user); })
      .catch(function () { /* silent — non-admin stays restricted */ });
  }

  // Load Poppins (matches NocoDB's NOCODB wordmark geometry).
  function loadFont() {
    if (document.getElementById('sheetshub-font')) return;
    const link = document.createElement('link');
    link.id = 'sheetshub-font';
    link.rel = 'stylesheet';
    link.href = 'https://fonts.googleapis.com/css2?family=Poppins:wght@800;900&display=swap';
    document.head.appendChild(link);
  }

  function makeWordmark() {
    const grey = '#4B5563';   // slate / gray-600
    const red = '#DC2626';    // accent dot

    const wrap = document.createElement('span');
    wrap.className = 'sheetshub-logo';
    wrap.innerHTML = `
      <svg viewBox="0 0 36 36" width="32" height="32" xmlns="http://www.w3.org/2000/svg" style="flex:none">
        <rect x="3" y="3" width="28" height="28" rx="5" fill="none" stroke="${grey}" stroke-width="2.5"/>
        <text x="17" y="25" text-anchor="middle" font-family="Poppins, system-ui, sans-serif" font-weight="900" font-size="22" fill="${grey}">S</text>
        <circle cx="33" cy="33" r="3.2" fill="${red}"/>
      </svg>
      <span style="color:${grey};font-family:Poppins,system-ui,sans-serif;font-weight:900;font-size:22px;letter-spacing:-0.01em;line-height:1">SHEETS</span>
    `;
    wrap.style.cssText = 'display:inline-flex;align-items:center;gap:8px;white-space:nowrap';
    return wrap;
  }

  function replaceLogos() {
    document.querySelectorAll('img[alt="NocoDB"]').forEach(function (img) {
      if (img.dataset.sheetshubReplaced) return;
      const wordmark = makeWordmark();
      img.parentNode.replaceChild(wordmark, img);
      wordmark.dataset.sheetshubReplaced = '1';
    });
  }

  function start() {
    loadFont();
    detect();
    replaceLogos();
    // NocoDB is a SPA — watch for DOM changes so newly-rendered logos
    // (e.g. after navigation) also get replaced.
    const observer = new MutationObserver(function () { replaceLogos(); });
    observer.observe(document.body, { childList: true, subtree: true });
  }

  if (document.body) {
    start();
  } else {
    document.addEventListener('DOMContentLoaded', start, { once: true });
  }
})();
