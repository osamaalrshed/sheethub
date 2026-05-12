// admin-detector.js — runs in every page load.
// 1) Admin detection: adds "is-admin" class to <body> if the logged-in user
//    matches ADMIN_EMAILS, which disables CSS hides for them.
// 2) Logo rebrand: replaces every NocoDB logo image with a "SheetsHub"
//    wordmark rendered as real HTML so it uses NocoDB's own page typography.
(function () {
  const ADMIN_EMAILS = ['admin@nocodb.local'];

  function applyAdmin(email) {
    if (ADMIN_EMAILS.indexOf(email) >= 0) {
      document.body.classList.add('is-admin');
    }
  }

  function detect() {
    fetch('/api/v1/auth/user/me', { credentials: 'include' })
      .then(function (r) { return r.ok ? r.json() : null; })
      .then(function (user) {
        if (user && user.email) applyAdmin(user.email);
      })
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
